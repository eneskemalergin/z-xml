#!/usr/bin/env python3
"""Check the shared persistent XML benchmark protocol."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path


EXPECTED_FIELDS = {
    "engine",
    "input",
    "consumer",
    "iterations",
    "chunk_bytes",
    "elements",
    "attributes",
    "text_bytes",
    "name_bytes",
    "value_bytes",
    "fragments",
    "accumulator",
}
EXPECTED_COUNTS = {
    "elements": 3,
    "attributes": 2,
    "text_bytes": 5,
    "name_bytes": 31,
    "value_bytes": 4,
}
EXPECTED_ACCUMULATOR = "eb797883fd275cc7"


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", type=Path)
    parser.add_argument("--z-xml-bin-dir", type=Path)
    parser.add_argument(
        "--input",
        type=Path,
        default=root / "bench" / "smoke" / "common.xml",
    )
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--max-input-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--max-output-bytes", type=int, default=64 * 1024)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.bin_dir is None and args.z_xml_bin_dir is None:
        print("select --bin-dir, --z-xml-bin-dir, or both", file=sys.stderr)
        return 64
    if (
        not math.isfinite(args.timeout)
        or args.timeout <= 0
        or args.max_input_bytes <= 0
        or args.max_output_bytes <= 0
    ):
        print("timeout and byte limits must be positive", file=sys.stderr)
        return 64

    targets: dict[str, Path] = {}
    if args.bin_dir is not None:
        targets.update(
            {
                "expat": args.bin_dir / "xml-ref-expat-persistent",
                "quick-xml": args.bin_dir / "xml-ref-quick-xml-persistent",
            }
        )
    if args.z_xml_bin_dir is not None:
        targets["z-xml"] = args.z_xml_bin_dir / "z-xml-persistent"
    for engine, program in targets.items():
        if not program.is_file():
            print(f"missing {engine} persistent adapter: {program}", file=sys.stderr)
            return 1
    if not args.input.is_file():
        print(f"missing smoke input: {args.input}", file=sys.stderr)
        return 1
    try:
        input_bytes = args.input.stat().st_size
    except OSError as error:
        print(error, file=sys.stderr)
        return 1
    if input_bytes > args.max_input_bytes:
        print(
            f"smoke input exceeds {args.max_input_bytes} bytes: {input_bytes}",
            file=sys.stderr,
        )
        return 1

    runs = 0
    for engine, program in targets.items():
        for input_model in ("resident", "stream"):
            for consumer in ("minimal", "full"):
                chunk_sizes = (4096,) if input_model == "resident" else (1, 7, 4096)
                for chunk_bytes in chunk_sizes:
                    command = [
                        program,
                        f"--input={input_model}",
                        f"--consumer={consumer}",
                        "--iterations=3",
                        f"--chunk-bytes={chunk_bytes}",
                        args.input,
                    ]
                    with (
                        tempfile.TemporaryFile() as stdout_stream,
                        tempfile.TemporaryFile() as stderr_stream,
                    ):
                        try:
                            completed = subprocess.run(
                                command,
                                stdin=subprocess.DEVNULL,
                                stdout=stdout_stream,
                                stderr=stderr_stream,
                                timeout=args.timeout,
                                check=False,
                            )
                        except subprocess.TimeoutExpired:
                            print(
                                f"{engine}/{input_model}/{consumer}/{chunk_bytes}: timeout",
                                file=sys.stderr,
                            )
                            return 1
                        except OSError as error:
                            print(f"{engine}: {error}", file=sys.stderr)
                            return 1
                        if (
                            stdout_stream.tell() > args.max_output_bytes
                            or stderr_stream.tell() > args.max_output_bytes
                        ):
                            print(f"{engine}: output exceeds byte limit", file=sys.stderr)
                            return 1
                        stdout_stream.seek(0)
                        stderr_stream.seek(0)
                        stdout = stdout_stream.read()
                        stderr = stderr_stream.read()
                    if completed.returncode != 0:
                        detail = stderr.decode("utf-8", "replace").strip()
                        if not detail:
                            detail = f"status {completed.returncode}"
                        print(
                            f"{engine}/{input_model}/{consumer}/{chunk_bytes}: {detail}",
                            file=sys.stderr,
                        )
                        return 1
                    if stderr:
                        print(f"{engine}: unexpected standard error", file=sys.stderr)
                        return 1
                    try:
                        observed = json.loads(stdout)
                    except (UnicodeDecodeError, json.JSONDecodeError) as error:
                        print(f"{engine}: invalid JSON: {error}", file=sys.stderr)
                        return 1
                    if (
                        not isinstance(observed, dict)
                        or set(observed) != EXPECTED_FIELDS
                    ):
                        print(f"{engine}: unexpected fields", file=sys.stderr)
                        return 1
                    expected_metadata = {
                        "engine": engine,
                        "input": input_model,
                        "consumer": consumer,
                        "iterations": 3,
                        "chunk_bytes": chunk_bytes,
                    }
                    if any(
                        observed[key] != value
                        for key, value in expected_metadata.items()
                    ):
                        print(f"{engine}: metadata mismatch", file=sys.stderr)
                        return 1
                    integer_fields = {
                        "iterations",
                        "chunk_bytes",
                        "elements",
                        "attributes",
                        "text_bytes",
                        "name_bytes",
                        "value_bytes",
                        "fragments",
                    }
                    if any(type(observed[field]) is not int for field in integer_fields):
                        print(f"{engine}: invalid numeric field", file=sys.stderr)
                        return 1
                    if any(
                        observed[key] != value for key, value in EXPECTED_COUNTS.items()
                    ):
                        print(f"{engine}: semantic count mismatch", file=sys.stderr)
                        return 1
                    expected_accumulator = (
                        EXPECTED_ACCUMULATOR if consumer == "full" else None
                    )
                    if observed["accumulator"] != expected_accumulator:
                        print(f"{engine}: accumulator mismatch", file=sys.stderr)
                        return 1
                    if (
                        type(observed["fragments"]) is not int
                        or observed["fragments"] <= 0
                    ):
                        print(f"{engine}: invalid fragment count", file=sys.stderr)
                        return 1
                    runs += 1

    expected_runs = len(targets) * 8
    if runs != expected_runs:
        print(
            f"persistent adapter protocol: expected {expected_runs} rows, got {runs}",
            file=sys.stderr,
        )
        return 1
    print(f"persistent adapter protocol: {runs} passes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
