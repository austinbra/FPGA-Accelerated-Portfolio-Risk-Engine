import struct
import subprocess
import unittest
from pathlib import Path

from src import uart_host


PARAMS = {
    "paths": 1024, "steps": 4, "S0": 100.0, "K": 100.0,
    "r": 0.05, "sigma": 0.2, "T": 1.0, "option_type": 1,
}


def response_bytes(params=PARAMS, price_word=391343, marker=uart_host.RESULT_MARKER,
                   cycles=72394):
    payload = uart_host._request_payload(params)
    return struct.pack("<8i", *payload) + struct.pack(
        "<4I", marker, price_word, cycles & 0xFFFFFFFF, cycles >> 32
    )


class FakeSerial:
    def __init__(self, data, max_chunk=3):
        self.data = bytearray(data)
        self.max_chunk = max_chunk
        self.timeout = None
        self.writes = bytearray()
        self.closed = False
        self.reset_count = 0

    def reset_input_buffer(self):
        # Preloaded bytes model future device responses, not stale input.
        self.reset_count += 1

    def write(self, data):
        self.writes.extend(data)
        return len(data)

    def flush(self):
        pass

    def read(self, size):
        count = min(size, self.max_chunk, len(self.data))
        result = bytes(self.data[:count])
        del self.data[:count]
        return result

    def close(self):
        self.closed = True


class Factory:
    def __init__(self, serial):
        self.serial = serial
        self.calls = 0

    def __call__(self, **_kwargs):
        self.calls += 1
        return self.serial


class UartHostTests(unittest.TestCase):
    def test_q16_rounding_matches_cpp_llround_and_range(self):
        half_lsb = 0.5 / 65536.0
        self.assertEqual(uart_host.float_to_q16_16(half_lsb), 1)
        self.assertEqual(uart_host.float_to_q16_16(-half_lsb), -1)
        self.assertEqual(uart_host.float_to_q16_16(32767.0), 32767 * 65536)
        with self.assertRaises(ValueError):
            uart_host.float_to_q16_16(32767.0001)

    def test_fragmented_four_word_packet_and_persistent_session(self):
        fake = FakeSerial(response_bytes() + response_bytes(), max_chunk=2)
        factory = Factory(fake)
        with uart_host.FpgaSession(
            "FAKE", timeout_s=0.1, num_lanes=4, serial_factory=factory
        ) as session:
            first = session.run_job(PARAMS)
            second = session.run_job(PARAMS)
        self.assertEqual(factory.calls, 1)
        self.assertEqual(first.price_raw, 391343)
        self.assertEqual(first.core_cycles, 72394)
        self.assertEqual(second.price_raw, first.price_raw)
        self.assertEqual(len(fake.writes), 64)
        self.assertTrue(fake.closed)

    def test_documented_fpga_errors_are_decoded(self):
        for code in (uart_host.CORE_TIMEOUT, uart_host.INVALID_WORKLOAD):
            with self.subTest(code=code):
                fake = FakeSerial(response_bytes(price_word=code))
                session = uart_host.FpgaSession(
                    "FAKE", timeout_s=0.1, num_lanes=4,
                    serial_factory=Factory(fake),
                )
                with self.assertRaises(uart_host.FpgaCoreError) as caught:
                    session.run_job(PARAMS)
                self.assertEqual(caught.exception.code, code)

    def test_bad_marker_is_rejected(self):
        fake = FakeSerial(response_bytes(marker=0xABCD0002))
        session = uart_host.FpgaSession(
            "FAKE", timeout_s=0.1, num_lanes=4, serial_factory=Factory(fake)
        )
        with self.assertRaises(uart_host.UartProtocolError):
            session.run_job(PARAMS)

    def test_invalid_job_fails_before_serial_factory(self):
        factory = Factory(FakeSerial(b""))
        session = uart_host.FpgaSession(
            "FAKE", timeout_s=0.01, num_lanes=4, serial_factory=factory
        )
        for update in ({"paths": 1025}, {"paths": 1023}, {"steps": 51},
                       {"S0": float("nan")}, {"K": 40000.0}, {"sigma": 0.0}):
            bad = dict(PARAMS)
            bad.update(update)
            with self.subTest(update=update), self.assertRaises(ValueError):
                session.run_job(bad)
        self.assertEqual(factory.calls, 0)
        with self.assertRaises(ValueError):
            uart_host.validate_fpga_params(PARAMS, 3)

    def test_truncated_packet_honors_deadline(self):
        fake = FakeSerial(response_bytes()[:-1], max_chunk=64)
        session = uart_host.FpgaSession(
            "FAKE", timeout_s=0.002, num_lanes=4, serial_factory=Factory(fake)
        )
        with self.assertRaises(TimeoutError):
            session.run_job(PARAMS)

    def test_release_build_and_explicit_cpu_mode(self):
        calls = []

        def build_runner(cmd, **kwargs):
            calls.append((cmd, kwargs))
            return subprocess.CompletedProcess(cmd, 0)

        uart_host.build_cpu_baseline(Path("baseline/cpp_fixed"), runner=build_runner)
        self.assertIn("-O3", calls[0][0])
        self.assertIn("-DNDEBUG", calls[0][0])
        self.assertIn("-pipe", calls[0][0])
        self.assertIn("cpu_build", calls[0][1]["env"]["TEMP"])

        def cpu_runner(cmd, **kwargs):
            calls.append((cmd, kwargs))
            output = (
                "Estimated Option Price (Q16.16): 391343\n"
                "Estimated Option Price (double): 5.97142\n"
                "Elapsed Time: 0.001 seconds\n"
            )
            return subprocess.CompletedProcess(cmd, 0, stdout=output, stderr="")

        result = uart_host.run_cpu_job(PARAMS, Path("baseline/cpp_fixed"),
                                       "multi", runner=cpu_runner)
        command = calls[1][0]
        mode_index = command.index("--exercise-mode")
        self.assertEqual(command[mode_index + 1], "multi")
        self.assertEqual(result.price_raw, 391343)
        self.assertEqual(result.price, 391343 / 65536.0)

    def test_parameter_file_preserves_exercise_mode(self):
        params = uart_host.load_params_file(
            Path("baseline/cpp_fixed/params_latency_1024x4.txt")
        )
        self.assertEqual(params["exercise_mode"], "multi")


if __name__ == "__main__":
    unittest.main()
