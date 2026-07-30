from __future__ import annotations

import json
import sys
import contextlib
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))

import reproduce_claims as claims  # noqa: E402


CPP_TEXT = """\
Option Type: PUT
Pricing Mode: FPGA_STYLE_MULTI_EXERCISE
Estimated Option Price (Q16.16): 391343
Estimated Option Price (double): 5.97142
Elapsed Time: 0.001134 seconds
"""

XSIM_TEXT = """\
****** xsim v2025.1 (64-bit)
[VIRTUAL_A7] paths=1024 steps=4 core_cycles=72394 price_raw=0x0005f8af marker=0xabcd0001
PASS: top UART echo/result packet check (1 batch(es))
"""

TIMING_TEXT = """\
| Tool Version : Vivado v.2025.1 (win64) Build 6140274
| Date         : Wed Jun 24 10:28:17 2026
| Design       : arty_a7_option_pricer_top
| Device       : xc7a100tcsg324-1
| Design State : Routed
Clock    Waveform(ns)       Period(ns)      Frequency(MHz)
-----    ------------       ----------      --------------
sys_clk  {0.000 5.000}      10.000          100.000
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints
    -------      -------  ---------------------  -------------------
      0.144        0.000                      0               126691
All user specified timing constraints are met.
  Requirement:            10.000ns  (sys_clk rise@10.000ns - sys_clk rise@0.000ns)
"""

UTIL_TEXT = """\
| Tool Version : Vivado v.2025.1 (win64) Build 6140274
| Date         : Wed Jun 24 10:28:17 2026
| Design       : arty_a7_option_pricer_top
| Device       : xc7a100tcsg324-1
| Design State : Routed
| Slice LUTs                 | 45875 | 0 | 0 | 63400 | 72.36 |
| Slice Registers            | 46911 | 0 | 0 | 126800 | 37.00 |
| Block RAM Tile             | 66 | 0 | 0 | 135 | 48.89 |
| DSPs                       | 180 | 0 | 0 | 240 | 75.00 |
"""

SOURCE_SNAPSHOT = {
    "combined_sha256": "fixture-source-sha256",
    "rtl": {"sha256": "rtl", "latest_source_mtime_ns": 100},
    "cpp": {"sha256": "cpp", "latest_source_mtime_ns": 100},
}
REPORT_FINGERPRINTS = {
    "timing_report": {"sha256": "timing", "mtime_ns": 200},
    "utilization_report": {"sha256": "util", "mtime_ns": 200},
}


def benchmark_document(repetitions: int = 15) -> dict:
    rows = []
    times_ms = {
        (4, "BM_EndToEndMultiPutMatrix"): 1.13,
        (4, "BM_PricingCoreMultiPutMatrix"): 0.90,
        (4, "BM_HotKernelMultiPutMatrix"): 0.80,
        (12, "BM_EndToEndMultiPutMatrix"): 1.86,
        (12, "BM_PricingCoreMultiPutMatrix"): 1.34,
        (12, "BM_HotKernelMultiPutMatrix"): 1.29,
    }
    for case in claims.CANONICAL_CASES:
        for benchmark_name in claims._BOUNDARY_BENCHMARKS.values():
            run_name = f"{benchmark_name}/{case.paths}/{case.steps}"
            value = times_ms[(case.steps, benchmark_name)]
            rows.append(
                {
                    "name": run_name + "_mean",
                    "run_name": run_name,
                    "run_type": "aggregate",
                    "aggregate_name": "mean",
                    "real_time": value,
                    "cpu_time": value - 0.01,
                    "time_unit": "ms",
                    "repetitions": repetitions,
                    "iterations": 10,
                    "label": f"Q16.16 price={case.expected_price_raw}",
                }
            )
    return {
        "context": {"library_version": "v1.9.4", "library_build_type": "release"},
        "benchmarks": rows,
    }


def assembled_fixture(
    *,
    benchmark_doc: dict | None = None,
    parsed_benchmark: dict | None = None,
    timing_text: str = TIMING_TEXT,
    utilization_text: str = UTIL_TEXT,
    compiler: str | None = "g++ test",
    benchmark_cpu: str | None = "Fixture CPU",
    modes: dict[str, str] | None = None,
    fingerprints: dict | None = None,
    parsed_source_fingerprint: str | None = None,
    parsed_git_commit: str | None = None,
) -> dict:
    cpp = {}
    xsim = {}
    for case in claims.CANONICAL_CASES:
        cpp[case.case_id] = {
            "price_raw_q16_16": case.expected_price_raw,
            "price": case.price,
            "process_elapsed_seconds": 0.001,
            "exercise_mode_label": "FPGA_STYLE_MULTI_EXERCISE",
            "option_type": "put",
        }
        xsim[case.case_id] = {
            "paths": case.paths,
            "steps": case.steps,
            "core_cycles": case.expected_core_cycles,
            "price_raw_q16_16": case.expected_price_raw,
            "price": case.price,
            "result_marker": claims.SUCCESS_MARKER,
            "xsim_version": "2025.1",
        }
    return claims.assemble_evidence(
        repo=REPO,
        cpp=cpp,
        xsim=xsim,
        benchmark=(
            parsed_benchmark
            if parsed_benchmark is not None
            else claims.parse_benchmark_json(benchmark_doc or benchmark_document())
        ),
        timing=claims.parse_timing_report(timing_text),
        utilization=claims.parse_utilization_report(utilization_text),
        clock_hz=100_000_000.0,
        compiler_version=compiler,
        benchmark_compiler_version=compiler,
        cpp_build_command=["g++", "-O3", "-DNDEBUG"] if compiler else None,
        benchmark_commands=None,
        reference_steps=256,
        skipped_sources=[],
        snapshots=SOURCE_SNAPSHOT,
        artifact_fingerprints=fingerprints or REPORT_FINGERPRINTS,
        collection_modes=modes,
        parsed_source_fingerprint=parsed_source_fingerprint,
        parsed_git_commit=parsed_git_commit,
        benchmark_cpu=benchmark_cpu,
    )


class ParserTests(unittest.TestCase):
    def test_cpp_output(self) -> None:
        parsed = claims.parse_cpp_output(CPP_TEXT)
        self.assertEqual(parsed["price_raw_q16_16"], 391343)
        self.assertEqual(parsed["exercise_mode_label"], "FPGA_STYLE_MULTI_EXERCISE")
        self.assertAlmostEqual(parsed["process_elapsed_seconds"], 0.001134)

    def test_xsim_output_and_signed_raw(self) -> None:
        parsed = claims.parse_xsim_output(XSIM_TEXT, claims.CANONICAL_CASES[0])
        self.assertEqual(parsed["result_marker"], claims.SUCCESS_MARKER)
        self.assertEqual(parsed["core_cycles"], 72394)
        self.assertEqual(parsed["price_raw_q16_16"], 391343)
        self.assertEqual(parsed["xsim_version"], "2025.1")

    def test_xsim_rejects_wrong_marker(self) -> None:
        bad = XSIM_TEXT.replace("0xabcd0001", "0xdead0001")
        with self.assertRaises(claims.EvidenceError):
            claims.parse_xsim_output(bad, claims.CANONICAL_CASES[0])

    def test_timing_and_utilization_reports(self) -> None:
        timing = claims.parse_timing_report(TIMING_TEXT)
        utilization = claims.parse_utilization_report(UTIL_TEXT)
        self.assertEqual(timing["wns_ns"], 0.144)
        self.assertEqual(timing["tns_ns"], 0.0)
        self.assertEqual(timing["setup_failing_endpoints"], 0)
        self.assertEqual(timing["clock_period_ns"], 10.0)
        self.assertEqual(timing["clock_frequency_mhz"], 100.0)
        self.assertEqual(utilization["slice_luts"]["used"], 45875)
        self.assertEqual(utilization["dsps"]["percent"], 75.0)

    def test_benchmark_boundaries_are_explicit(self) -> None:
        parsed = claims.parse_benchmark_json(benchmark_document())
        rows = parsed["cases"]["put_1024x4_multi"]
        self.assertEqual(set(rows), {"end_to_end", "pricing_core", "hot_kernel"})
        self.assertAlmostEqual(rows["end_to_end"]["mean_real_seconds"], 0.00113)
        self.assertEqual(rows["end_to_end"]["repetitions"], 15)

    def test_run_commands_bind_selected_tool_configuration(self) -> None:
        configure = claims.benchmark_configure_command(
            REPO, REPO / ".tmp" / "claim-benchmark", "selected-cxx"
        )
        self.assertIn("-DCMAKE_CXX_COMPILER=selected-cxx", configure)
        vivado = claims.vivado_route_command(REPO, 1234, "powershell.exe")
        self.assertIn("-MultiExercise", vivado)
        self.assertEqual(vivado[vivado.index("-NumLanes") + 1], "4")
        self.assertEqual(vivado[vivado.index("-ClockPeriodNs") + 1], "10.0")
        self.assertEqual(vivado[vivado.index("-TimeoutSeconds") + 1], "1234")


class OutputTests(unittest.TestCase):
    def test_complete_evidence_and_outputs(self) -> None:
        cpp = {}
        xsim = {}
        for case in claims.CANONICAL_CASES:
            cpp[case.case_id] = {
                "price_raw_q16_16": case.expected_price_raw,
                "price": case.price,
                "process_elapsed_seconds": 0.001,
                "exercise_mode_label": "FPGA_STYLE_MULTI_EXERCISE",
                "option_type": "put",
            }
            xsim[case.case_id] = {
                "paths": case.paths,
                "steps": case.steps,
                "core_cycles": case.expected_core_cycles,
                "price_raw_q16_16": case.expected_price_raw,
                "price": case.price,
                "result_marker": claims.SUCCESS_MARKER,
                "xsim_version": "2025.1",
            }
        evidence = claims.assemble_evidence(
            repo=REPO,
            cpp=cpp,
            xsim=xsim,
            benchmark=claims.parse_benchmark_json(benchmark_document()),
            timing=claims.parse_timing_report(TIMING_TEXT),
            utilization=claims.parse_utilization_report(UTIL_TEXT),
            clock_hz=100_000_000.0,
            compiler_version="g++ test",
            cpp_build_command=["g++", "-O3", "-DNDEBUG"],
            benchmark_commands=None,
            reference_steps=1024,
            skipped_sources=[],
            snapshots=SOURCE_SNAPSHOT,
            artifact_fingerprints=REPORT_FINGERPRINTS,
        )
        self.assertTrue(evidence["claim_ready"])
        case4 = evidence["cases"][0]
        self.assertAlmostEqual(
            case4["rtl_xsim_four_lane"]["core_latency_seconds"], 0.00072394
        )
        self.assertAlmostEqual(
            case4["cpu_boundaries"]["end_to_end"][
                "cpu_mean_real_over_fpga_core_ratio"
            ],
            0.00113 / 0.00072394,
        )
        self.assertLess(
            case4["financial_reference"]["signed_error_bps_of_spot"], 0.0
        )

        markdown = claims.render_markdown(evidence)
        self.assertIn("CPU mean real time / FPGA core time", markdown)
        self.assertNotIn("Speedup", markdown)
        scratch_root = REPO / '.tmp'
        scratch_root.mkdir(exist_ok=True)
        with contextlib.nullcontext(scratch_root / 'test-reproduce-claims-output') as temp:
            Path(temp).mkdir(parents=True, exist_ok=True)
            output = Path(temp)
            evidence["provenance"]["host"] = "private-build-host"
            evidence["provenance"]["google_benchmark"] = {
                "host_name": "private-build-host",
                "executable": str(REPO / ".tmp" / "benchmark.exe"),
            }
            claims.write_outputs(output, evidence, repo=REPO)
            json_text = (output / "claim_evidence.json").read_text()
            loaded = json.loads(json_text)
            self.assertTrue(loaded["claim_ready"])
            self.assertNotIn("host", loaded["provenance"])
            self.assertNotIn(
                "host_name", loaded["provenance"]["google_benchmark"]
            )
            self.assertNotIn("private-build-host", json_text)
            self.assertNotIn(str(REPO), json_text)
            self.assertEqual(
                loaded["provenance"]["google_benchmark"]["executable"],
                "./.tmp/benchmark.exe",
            )
            self.assertTrue((output / "claim_evidence.csv").is_file())
            self.assertTrue((output / "claim_evidence.md").is_file())

    def test_short_benchmark_run_is_not_claim_ready(self) -> None:
        cpp = {}
        xsim = {}
        for case in claims.CANONICAL_CASES:
            cpp[case.case_id] = {
                "price_raw_q16_16": case.expected_price_raw,
                "price": case.price,
                "process_elapsed_seconds": 0.001,
                "exercise_mode_label": "FPGA_STYLE_MULTI_EXERCISE",
                "option_type": "put",
            }
            xsim[case.case_id] = {
                "paths": case.paths,
                "steps": case.steps,
                "core_cycles": case.expected_core_cycles,
                "price_raw_q16_16": case.expected_price_raw,
                "price": case.price,
                "result_marker": claims.SUCCESS_MARKER,
                "xsim_version": "2025.1",
            }
        evidence = claims.assemble_evidence(
            repo=REPO,
            cpp=cpp,
            xsim=xsim,
            benchmark=claims.parse_benchmark_json(benchmark_document(10)),
            timing=claims.parse_timing_report(TIMING_TEXT),
            utilization=claims.parse_utilization_report(UTIL_TEXT),
            clock_hz=100_000_000.0,
            compiler_version=None,
            cpp_build_command=None,
            benchmark_commands=None,
            reference_steps=256,
            skipped_sources=[],
            snapshots=SOURCE_SNAPSHOT,
            artifact_fingerprints=REPORT_FINGERPRINTS,
        )
        self.assertFalse(evidence["claim_ready"])
        self.assertTrue(evidence["validation"]["problems"])

    def test_nonrelease_benchmark_is_not_claim_ready(self) -> None:
        document = benchmark_document()
        document["context"]["library_build_type"] = "debug"
        evidence = assembled_fixture(benchmark_doc=document)
        self.assertFalse(evidence["claim_ready"])
        self.assertTrue(
            any("library_build_type=release" in item for item in evidence["validation"]["problems"])
        )

    def test_missing_case_benchmark_evidence_is_not_claim_ready(self) -> None:
        parsed = claims.parse_benchmark_json(benchmark_document())
        del parsed["cases"]["put_1024x12_multi"]
        evidence = assembled_fixture(parsed_benchmark=parsed)
        self.assertFalse(evidence["claim_ready"])
        self.assertTrue(
            any(
                "missing CPU boundary benchmark evidence for put_1024x12_multi" in item
                for item in evidence["validation"]["problems"]
            )
        )

    def test_mismatched_nonrouted_reports_are_not_claim_ready(self) -> None:
        bad_util = UTIL_TEXT.replace("xc7a100tcsg324-1", "xc7s50csga324-1").replace(
            "Design State : Routed", "Design State : Synthesized"
        )
        evidence = assembled_fixture(utilization_text=bad_util)
        self.assertFalse(evidence["claim_ready"])
        problems = "\n".join(evidence["validation"]["problems"])
        self.assertIn("not Routed", problems)
        self.assertIn("devices do not match", problems)

    def test_missing_or_mismatched_report_metadata_is_not_claim_ready(self) -> None:
        bad_timing = TIMING_TEXT.replace(
            "| Tool Version : Vivado v.2025.1 (win64) Build 6140274\n", ""
        )
        bad_util = UTIL_TEXT.replace(
            "arty_a7_option_pricer_top", "different_implementation_top"
        )
        evidence = assembled_fixture(
            timing_text=bad_timing, utilization_text=bad_util
        )
        self.assertFalse(evidence["claim_ready"])
        problems = "\n".join(evidence["validation"]["problems"])
        self.assertIn("missing tool metadata", problems)
        self.assertIn("implementation tops do not match", problems)

    def test_stale_route_and_missing_compiler_are_not_claim_ready(self) -> None:
        stale = {
            "timing_report": {"sha256": "timing", "mtime_ns": 99},
            "utilization_report": {"sha256": "util", "mtime_ns": 99},
        }
        evidence = assembled_fixture(compiler=None, fingerprints=stale)
        self.assertFalse(evidence["claim_ready"])
        problems = "\n".join(evidence["validation"]["problems"])
        self.assertIn("compiler provenance", problems)
        self.assertIn("predate the latest RTL", problems)

    def test_parse_mode_requires_explicit_source_binding(self) -> None:
        modes = {name: "parse" for name in ("cpp", "xsim", "benchmark", "vivado")}
        missing = assembled_fixture(modes=modes)
        self.assertFalse(missing["claim_ready"])
        problems = "\n".join(missing["validation"]["problems"])
        self.assertIn("--parsed-git-commit", problems)
        self.assertIn("--parsed-source-fingerprint", problems)

        commit = claims._git_value(REPO, "rev-parse", "HEAD")
        no_cpu = assembled_fixture(
            modes=modes,
            parsed_git_commit=commit,
            parsed_source_fingerprint=SOURCE_SNAPSHOT["combined_sha256"],
            benchmark_cpu=None,
        )
        self.assertFalse(no_cpu["claim_ready"])
        self.assertTrue(
            any(
                "CPU provenance" in item
                for item in no_cpu["validation"]["problems"]
            )
        )
        bound = assembled_fixture(
            modes=modes,
            parsed_git_commit=commit,
            parsed_source_fingerprint=SOURCE_SNAPSHOT["combined_sha256"],
        )
        self.assertTrue(bound["claim_ready"])


if __name__ == "__main__":
    unittest.main()
