#!/usr/bin/env python3
"""Stress the minimal S7 UART diagnostic without using the host pacing fix."""

from __future__ import annotations

import argparse
import struct
import time

import serial


REQUEST = (
    1024,
    4,
    0x00640000,
    0x00640000,
    0x00000CCD,
    0x00003333,
    0x00010000,
    1,
)
RESULT_MARKER = 0xABCD0001


def read_exact(port: serial.Serial, size: int) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + float(port.timeout or 1.0)
    while len(data) < size:
        chunk = port.read(size - len(data))
        if chunk:
            data.extend(chunk)
            continue
        if time.monotonic() >= deadline:
            raise TimeoutError(f"received {len(data)} of {size} bytes")
    return bytes(data)


def send_request(port: serial.Serial, word_gap_ms: float) -> None:
    if word_gap_ms <= 0:
        port.write(struct.pack("<8i", *REQUEST))
        port.flush()
        return
    for word in REQUEST:
        port.write(struct.pack("<i", word))
        port.flush()
        time.sleep(word_gap_ms / 1000.0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--repetitions", type=int, default=100)
    parser.add_argument("--word-gap-ms", type=float, default=0.0)
    parser.add_argument("--timeout", type=float, default=3.0)
    parser.add_argument("--expected-cpb", type=int)
    parser.add_argument("--expected-domain", choices=("board100", "core95"))
    args = parser.parse_args()

    expected_tag = {
        "board100": 0xD1A60000,
        "core95": 0xD1A60001,
        None: None,
    }[args.expected_domain]

    last_diag = None
    started = time.monotonic()
    with serial.Serial(args.port, args.baud, timeout=args.timeout) as port:
        port.reset_input_buffer()
        for repetition in range(1, args.repetitions + 1):
            send_request(port, args.word_gap_ms)
            echo = struct.unpack("<8i", read_exact(port, 32))
            marker, measured_edges, cpb, domain_tag = struct.unpack(
                "<4I", read_exact(port, 16)
            )
            if echo != REQUEST:
                raise RuntimeError(
                    f"repetition {repetition}: echo mismatch\n"
                    f"expected={REQUEST!r}\nreceived={echo!r}"
                )
            if marker != RESULT_MARKER:
                raise RuntimeError(
                    f"repetition {repetition}: marker=0x{marker:08X}"
                )
            if args.expected_cpb is not None and cpb != args.expected_cpb:
                raise RuntimeError(
                    f"repetition {repetition}: CPB {cpb}, expected {args.expected_cpb}"
                )
            if expected_tag is not None and domain_tag != expected_tag:
                raise RuntimeError(
                    f"repetition {repetition}: domain tag 0x{domain_tag:08X}, "
                    f"expected 0x{expected_tag:08X}"
                )
            last_diag = measured_edges, cpb, domain_tag

    elapsed = time.monotonic() - started
    measured_edges, cpb, domain_tag = last_diag
    print(
        f"PASS repetitions={args.repetitions} gap_ms={args.word_gap_ms:.3f} "
        f"elapsed_s={elapsed:.3f}"
    )
    print(
        f"DIAG measured_core_edges_per_10ms={measured_edges} "
        f"measured_core_hz={measured_edges * 100} cpb={cpb} "
        f"domain_tag=0x{domain_tag:08X}"
    )


if __name__ == "__main__":
    main()
