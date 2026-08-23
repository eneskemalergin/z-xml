#!/usr/bin/env python3
"""Check the shared persistent XML benchmark protocol."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
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
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--z-xml-bin-dir", type=Path)
    parser.add_argument(
        "--input",
        type=Path,
        default=root / "bench" / "smoke" / "common.xml",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    targets = {
        "expat": args.bin_dir / "xml-ref-expat-persistent",
        "quick-xml": args.bin_dir / "xml-ref-quick-xml-persistent",
    }
    if args.z_xml_bin_dir is not None:
        targets["z-xml"] = args.z_xml_bin_dir / "z-xml-persistent"
    for engine, program in targets.items():
        if not program.is_file():
            print(f"missing {engine} persistent adapter: {program}", file=sys.stderr)
            return 1
    if not args.input.is_file():
        print(f"missing smoke input: {args.input}", file=sys.stderr)
        return 1

    runs = 0
    for engine, program in targets.items():
        for input_model in ("resident", "stream"):
            for consumer in ("minimal", "full"):
                for chunk_bytes in (1, 7, 4096):
                    command = [
                        program,
                        f"--input={input_model}",
                        f"--consumer={consumer}",
                        "--iterations=3",
                        f"--chunk-bytes={chunk_bytes}",
                        args.input,
                    ]
                    completed = subprocess.run(
                        command,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=10,
                        check=False,
                    )
                    if completed.returncode != 0:
                        detail = completed.stderr.decode("utf-8", "replace").strip()
                        print(
                            f"{engine}/{input_model}/{consumer}/{chunk_bytes}: {detail}",
                            file=sys.stderr,
                        )
                        return 1
                    try:
                        observed = json.loads(completed.stdout)
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

    print(f"persistent adapter protocol: {runs} passes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
