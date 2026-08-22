#!/usr/bin/env python3
"""Measure one exact command through two names to establish zebrac host noise."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def resolve_zebrac(explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit.resolve()
    command = shutil.which("zebrac")
    return Path(command).resolve() if command is not None else None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--program", type=Path, required=True)
    parser.add_argument("--arg", action="append", default=[])
    parser.add_argument(
        "--zebrac",
        type=Path,
        help="Zebrac executable (default: resolve zebrac from PATH)",
    )
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


def validate_zebrac_results(
    path: Path, commands: list[str], samples: int, allow_failures: bool
) -> str | None:
    try:
        with path.open(encoding="utf-8") as stream:
            report = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        return f"invalid zebrac JSON: {error}"
    if not isinstance(report, dict) or report.get("schema_version") != 1:
        return "unexpected zebrac JSON schema"
    config = report.get("config")
    results = report.get("results")
    if not isinstance(config, dict) or not isinstance(results, list):
        return "incomplete zebrac JSON"
    if config.get("min_samples") != samples or config.get("max_samples") != samples:
        return "zebrac sample count differs from requested count"
    if len(results) != len(commands):
        return "zebrac result count differs from command count"
    for index, result in enumerate(results):
        if not isinstance(result, dict):
            return f"invalid zebrac result at index {index}"
        if result.get("command") != commands[index]:
            return f"zebrac command differs at index {index}"
        sample_count = result.get("sample_count")
        failed_sample_count = result.get("failed_sample_count")
        if (
            type(sample_count) is not int
            or type(failed_sample_count) is not int
            or sample_count != samples
            or failed_sample_count < 0
            or failed_sample_count > sample_count
        ):
            return f"invalid zebrac sample counts at index {index}"
        if not allow_failures and failed_sample_count != 0:
            return f"unexpected failed zebrac samples at index {index}"
    return None


def main() -> int:
    args = parse_args()
    if args.duration_ms <= 0 or args.samples <= 1 or args.warmups < 0:
        print(
            "duration must be positive, samples must exceed one, and warmups may be zero",
            file=sys.stderr,
        )
        return 64

    program = args.program.resolve()
    zebrac = resolve_zebrac(args.zebrac)
    if not program.is_file():
        print(f"missing program: {program}", file=sys.stderr)
        return 1
    if zebrac is None:
        print("zebrac not found on PATH; pass --zebrac PATH", file=sys.stderr)
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
    result_error = None
    if completed.returncode == 0:
        result_error = validate_zebrac_results(
            raw_path,
            commands,
            args.samples,
            args.allow_failures,
        )
    metadata = {
        "schema": "z-xml-zebrac-aa-v2",
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
        "zebrac_result_error": result_error,
        "raw": raw_path.name,
        "stdout": stdout_path.name,
        "stderr": stderr_path.name,
    }
    temporary = args.output_dir / "index.json.tmp"
    temporary.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.output_dir / "index.json")
    if completed.returncode != 0:
        return completed.returncode
    return 1 if result_error is not None else 0


if __name__ == "__main__":
    raise SystemExit(main())
