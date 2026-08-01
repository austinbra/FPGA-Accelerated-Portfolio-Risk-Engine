#!/usr/bin/env python3
"""Stress the full FPGA UART protocol and decode framing diagnostics."""

import argparse
import struct
import time

import serial


REQUEST_WORDS = (
    1024,
    4,
    0x00640000,
    0x00640000,
    0x00000CCD,
    0x00003333,
    0x00010000,
    1,
)
REQUEST = struct.pack("<8I", *REQUEST_WORDS)
EXPECTED_PRICE = 391343


def read_exact(port: serial.Serial, size: int, timeout_s: float) -> bytes:
    deadline = time.monotonic() + timeout_s
    data = bytearray()
    while len(data) < size:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"received {len(data)} of {size} bytes")
        chunk = port.read(size - len(data))
        if chunk:
            data.extend(chunk)
    return bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--repetitions", type=int, default=100)
    parser.add_argument("--packet-timeout-s", type=float, default=0.5)
    parser.add_argument("--settle-ms", type=float, default=100.0)
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.02) as port:
        port.reset_input_buffer()
        time.sleep(args.settle_ms / 1000.0)

        for iteration in range(1, args.repetitions + 1):
            port.write(REQUEST)
            port.flush()

            first = read_exact(port, 4, args.packet_timeout_s)
            first_word = struct.unpack("<I", first)[0]
            if first_word >> 16 == 0xBADF:
                diagnostic = struct.unpack(
                    "<4I",
                    first + read_exact(port, 12, args.packet_timeout_s),
                )
                location = diagnostic[0] & 0x1F
                word_index = (location >> 2) & 0x7
                accepted_bytes = location & 0x3
                raise RuntimeError(
                    "FPGA framing error at "
                    f"iteration={iteration} word={word_index} "
                    f"accepted_bytes={accepted_bytes} "
                    f"packet={[f'0x{word:08X}' for word in diagnostic]}"
                )

            echo_bytes = first + read_exact(port, 28, args.packet_timeout_s)
            echoes = struct.unpack("<8I", echo_bytes)
            if echoes != REQUEST_WORDS:
                raise RuntimeError(
                    f"echo mismatch at iteration={iteration}: "
                    f"{[f'0x{word:08X}' for word in echoes]}"
                )

            result = struct.unpack(
                "<4I", read_exact(port, 16, args.packet_timeout_s)
            )
            if result[0] != 0xABCD0001 or result[1] != EXPECTED_PRICE:
                raise RuntimeError(
                    f"result mismatch at iteration={iteration}: "
                    f"{[f'0x{word:08X}' for word in result]}"
                )

            if iteration == 1 or iteration % 25 == 0:
                print(
                    f"PASS iteration={iteration} price={result[1]} "
                    f"cycles={result[2]}"
                )

    print(f"UART_STRESS_PASS repetitions={args.repetitions} request_gap_ms=0")


if __name__ == "__main__":
    main()
