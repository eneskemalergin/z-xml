#!/usr/bin/env python3
"""Measure one exact command through two names to establish zebrac host noise."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--program", type=Path, required=True)
    parser.add_argument("--arg", action="append", default=[])
    parser.add_argument("--zebrac", type=Path, default=root / "tools" / "zebrac")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--duration-ms", type=int, default=5000)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--warmups", type=int, default=5)
    parser.add_argument("--allow-failures", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def host_information() -> dict[str, object]:
    return {
        "system": platform.system(),
        "kernel": platform.release(),
        "machine": platform.machine(),
        "logical_cpu_count": os.cpu_count(),
        "libc": platform.libc_ver(),
    }


def main() -> int:
    args = parse_args()
    if args.duration_ms <= 0 or args.samples <= 1 or args.warmups < 0:
        print(
            "duration must be positive, samples must exceed one, and warmups may be zero",
            file=sys.stderr,
        )
        return 64

    program = args.program.resolve()
    zebrac = args.zebrac.resolve()
    if not program.is_file():
        print(f"missing program: {program}", file=sys.stderr)
        return 1
    if not zebrac.is_file():
        print(f"missing zebrac: {zebrac}", file=sys.stderr)
        return 1

    canonical = [str(program), *args.arg]
    if args.dry_run:
        print(shlex.join(canonical))
        print(
            f"duration_ms={args.duration_ms} samples={args.samples} "
            f"warmups={args.warmups}"
        )
        return 0

    args.output_dir.mkdir(parents=True, exist_ok=True)
    raw_path = args.output_dir / "zebrac.json"
    stdout_path = args.output_dir / "zebrac.stdout.txt"
    stderr_path = args.output_dir / "zebrac.stderr.txt"

    with tempfile.TemporaryDirectory(prefix="z-xml-aa-", dir=args.output_dir) as temp:
        temp_dir = Path(temp)
        left = temp_dir / "aa-left"
        right = temp_dir / "aa-right"
        left.symlink_to(program)
        right.symlink_to(program)
        commands = [
            shlex.join([str(left), *args.arg]),
            shlex.join([str(right), *args.arg]),
        ]
        command = [
            str(zebrac),
            "--duration",
            str(args.duration_ms),
            "--min-samples",
            str(args.samples),
            "--max-samples",
            str(args.samples),
            "--warmup",
            str(args.warmups),
            f"--json={raw_path}",
        ]
        if args.allow_failures:
            command.append("--allow-failures")
        command.append("--")
        command.extend(commands)
        completed = subprocess.run(command, text=True, capture_output=True, check=False)

    stdout_path.write_text(completed.stdout, encoding="utf-8")
    stderr_path.write_text(completed.stderr, encoding="utf-8")
    metadata = {
        "schema": "z-xml-zebrac-aa-v1",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "program": str(program),
        "program_size": program.stat().st_size,
        "arguments": args.arg,
        "sampling": {
            "duration_ms": args.duration_ms,
            "samples": args.samples,
            "warmups": args.warmups,
        },
        "host": host_information(),
        "zebrac": str(zebrac),
        "zebrac_status": completed.returncode,
        "raw": raw_path.name,
        "stdout": stdout_path.name,
        "stderr": stderr_path.name,
    }
    temporary = args.output_dir / "index.json.tmp"
    temporary.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.output_dir / "index.json")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
