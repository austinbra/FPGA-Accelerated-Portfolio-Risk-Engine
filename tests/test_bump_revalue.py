import json
import unittest
from pathlib import Path

from scripts import bump_revalue
from src.uart_host import CpuResult, FpgaResult, RESULT_MARKER


BASE = {
    "paths": 1024, "steps": 12, "S0": 100.0, "K": 100.0,
    "r": 0.05, "sigma": 0.2, "T": 1.0, "option_type": 1,
}


def model_raw(params):
    # Deliberately simple surface with known finite differences.
    price = 10.0 - 0.5 * (float(params["S0"]) - 100.0)
    price += 20.0 * (float(params["sigma"]) - 0.2)
    return round(price * 65536)


def cpu_runner(params, _baseline_dir, exercise_mode):
    assert exercise_mode == "multi"
    raw = model_raw(params)
    return CpuResult("", raw, raw / 65536.0, 0.001)


class FakeBumpSession:
    instances = []
    mismatch = False

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.jobs = []
        self.closed = False
        self.__class__.instances.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.closed = True

    def run_job(self, params):
        self.jobs.append(dict(params))
        raw = model_raw(params)
        if self.mismatch and not any(job for job in self.jobs[:-1]):
            raw += 1
        return FpgaResult(
            echoes=(), marker=RESULT_MARKER, price_word=raw,
            price_raw=raw, price=raw / 65536.0,
            core_cycles=1000, transport_s=0.01,
        )


class BumpRevalueTests(unittest.TestCase):
    def setUp(self):
        FakeBumpSession.instances = []
        FakeBumpSession.mismatch = False

    def test_scenarios_and_bump_validation(self):
        scenarios, spot_step, vol_step = bump_revalue.build_scenarios(BASE)
        self.assertEqual(tuple(scenarios), bump_revalue.SCENARIO_ORDER)
        self.assertEqual(spot_step, 1.0)
        self.assertEqual(vol_step, 0.01)
        self.assertEqual(scenarios["spot_up"]["S0"], 101.0)
        self.assertEqual(scenarios["spot_down"]["S0"], 99.0)
        with self.assertRaises(ValueError):
            bump_revalue.build_scenarios({**BASE, "sigma": 0.005})

    def test_both_targets_use_one_persistent_session_and_exact_parity(self):
        rows, greeks, metadata = bump_revalue.run_workflow(
            BASE, "both", Path("baseline/cpp_fixed"), cpu_runner=cpu_runner,
            fpga_session_factory=FakeBumpSession,
        )
        self.assertEqual(len(rows), 10)
        self.assertEqual(len(FakeBumpSession.instances), 1)
        self.assertEqual(len(FakeBumpSession.instances[0].jobs), 5)
        self.assertTrue(FakeBumpSession.instances[0].closed)
        self.assertTrue(metadata["common_random_numbers"])
        self.assertAlmostEqual(greeks["cpu"]["delta"], -0.5, places=4)
        self.assertAlmostEqual(greeks["cpu"]["gamma"], 0.0, places=4)
        self.assertAlmostEqual(greeks["cpu"]["vega"], 20.0, places=2)
        self.assertEqual(greeks["cpu"], greeks["fpga"])

    def test_both_target_raw_mismatch_fails_before_greeks(self):
        FakeBumpSession.mismatch = True
        with self.assertRaisesRegex(RuntimeError, r"raw C\+\+/FPGA mismatch"):
            bump_revalue.run_workflow(
                BASE, "both", Path("baseline/cpp_fixed"), cpu_runner=cpu_runner,
                fpga_session_factory=FakeBumpSession,
            )

    def test_json_and_csv_outputs_have_required_boundaries(self):
        rows, greeks, metadata = bump_revalue.run_workflow(
            BASE, "cpu", Path("baseline/cpp_fixed"), cpu_runner=cpu_runner,
        )
        output_dir = Path(".tmp") / "test_bump_revalue"
        csv_path, json_path = output_dir / "risk.csv", output_dir / "risk.json"
        bump_revalue.write_outputs(rows, greeks, metadata, csv_path, json_path)
        self.addCleanup(csv_path.unlink, missing_ok=True)
        self.addCleanup(json_path.unlink, missing_ok=True)
        self.assertIn("core_seconds", csv_path.read_text(encoding="utf-8"))
        document = json.loads(json_path.read_text(encoding="utf-8"))
        self.assertEqual(document["results"][0]["status"], "OK")
        self.assertIn("cpu_reported_seconds", document["results"][0])


if __name__ == "__main__":
    unittest.main()
