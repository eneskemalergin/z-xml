#!/usr/bin/env python3
"""Run Valgrind Memcheck on correctness-qualified reference adapters."""

from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMAS = {"z-xml-generated-v2", "z-xml-generated-v3"}
MAX_WORKLOAD_BYTES = 1024 * 1024 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--eligibility", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--valgrind", default="valgrind")
    parser.add_argument("--workload", action="append", required=True)
    parser.add_argument("--target", action="append", required=True)
    parser.add_argument("--timeout", type=float, default=120.0)
    return parser.parse_args()


def read_manifest(path: Path) -> dict[str, dict[str, str]]:
    root = path.parent.resolve()
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    comments = {line[1:].strip() for line in lines if line.startswith("#")}
    if not SCHEMAS.intersection(comments):
        raise ValueError(f"{path}: unsupported generated-corpus schema")
    if f"size ceiling: {MAX_WORKLOAD_BYTES} bytes" not in comments:
        raise ValueError(f"{path}: unexpected workload ceiling")
    required = {
        "id",
        "path",
        "target_bytes",
        "actual_bytes",
        "classification",
    }
    reader = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    if reader.fieldnames is None or required.difference(reader.fieldnames):
        raise ValueError(f"{path}: incomplete generated manifest")
    result: dict[str, dict[str, str]] = {}
    for row in reader:
        if row["id"] in result:
            raise ValueError(f"duplicate workload ID {row['id']}")
        if row["classification"] not in {"benchmark-valid", "not-well-formed"}:
            raise ValueError(f"unsupported classification {row['classification']}")
        result[row["id"]] = row
    seen_paths: set[Path] = set()
    for row in result.values():
        resolved = (root / row["path"]).resolve()
        try:
            resolved.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{row['id']}: path escapes corpus") from error
        if resolved in seen_paths:
            raise ValueError(f"{row['id']}: duplicate workload path")
        seen_paths.add(resolved)
        row["resolved_path"] = str(resolved)
    return result


def read_targets(path: Path, bin_dir: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 6:
                raise ValueError(f"{path}:{line_number}: expected 6 fields")
            if fields[0] in result:
                raise ValueError(f"{path}:{line_number}: duplicate target {fields[0]}")
            result[fields[0]] = (bin_dir / fields[1]).resolve()
    return result


def read_passing(path: Path) -> set[tuple[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return {
            (row["target"], row["workload"])
            for row in csv.DictReader(stream, delimiter="\t")
            if row["verdict"] == "pass"
        }


def safe_name(value: str) -> str:
    return "".join(
        character if character.isalnum() or character in "-_" else "_"
        for character in value
    )


def main() -> int:
    args = parse_args()
    if args.timeout <= 0:
        print("timeout must be positive", file=sys.stderr)
        return 64
    try:
        workloads = read_manifest(args.manifest)
        targets = read_targets(args.targets, args.bin_dir.resolve())
        passing = read_passing(args.eligibility)
    except (OSError, KeyError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    unknown_workloads = set(args.workload).difference(workloads)
    unknown_targets = set(args.target).difference(targets)
    if unknown_workloads or unknown_targets:
        print(
            "unknown selections: "
            + ",".join(sorted(unknown_workloads | unknown_targets)),
            file=sys.stderr,
        )
        return 64
    pairs = [
        (target, workload)
        for target in args.target
        for workload in args.workload
        if (target, workload) in passing
    ]
    if not pairs:
        print("no selected pairs passed the correctness gate", file=sys.stderr)
        return 1
    for workload_name in dict.fromkeys(workload for _target, workload in pairs):
        workload = workloads[workload_name]
        path = Path(workload["resolved_path"])
        try:
            actual_size = path.stat().st_size
            manifest_size = int(workload["actual_bytes"])
            target_size = int(workload["target_bytes"])
        except (OSError, ValueError) as error:
            print(f"{workload_name}: {error}", file=sys.stderr)
            return 1
        if (
            actual_size != manifest_size
            or (target_size and actual_size != target_size)
            or actual_size > MAX_WORKLOAD_BYTES
        ):
            print(
                f"{workload_name}: generated bytes differ from manifest",
                file=sys.stderr,
            )
            return 1
    valgrind = shutil.which(args.valgrind)
    if valgrind is None:
        print(f"Valgrind executable not found: {args.valgrind}", file=sys.stderr)
        return 1
    version = subprocess.run(
        [valgrind, "--version"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    ).stdout.strip()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    metadata = {
        "schema": "z-xml-valgrind-v2",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "valgrind": str(Path(valgrind).resolve()),
        "valgrind_version": version,
        "manifest": str(args.manifest.resolve()),
        "eligibility": str(args.eligibility.resolve()),
        "targets": str(args.targets.resolve()),
        "bin_dir": str(args.bin_dir.resolve()),
        "timeout_seconds": args.timeout,
        "workloads": args.workload,
        "selected_targets": args.target,
        "target_binaries": {
            target_name: {
                "path": str(targets[target_name]),
                "size": targets[target_name].stat().st_size,
            }
            for target_name in dict.fromkeys(target for target, _workload in pairs)
        },
        "memcheck_options": [
            "--leak-check=full",
            "--show-leak-kinds=definite,indirect,possible",
            "--errors-for-leak-kinds=definite,indirect",
            "--track-fds=yes",
            "--error-exitcode=99",
        ],
    }
    (args.output_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    results_path = args.output_dir / "results.tsv"
    rows: list[dict[str, str | int]] = []
    had_error = False
    for target_name, workload_name in pairs:
        target = targets[target_name]
        workload = workloads[workload_name]
        if not target.is_file() or not Path(workload["resolved_path"]).is_file():
            print(f"missing input for {target_name}/{workload_name}", file=sys.stderr)
            return 1
        log = (
            args.output_dir
            / f"{safe_name(target_name)}--{safe_name(workload_name)}.log"
        )
        command = [
            valgrind,
            "--tool=memcheck",
            "--leak-check=full",
            "--show-leak-kinds=definite,indirect,possible",
            "--errors-for-leak-kinds=definite,indirect",
            "--track-fds=yes",
            "--error-exitcode=99",
            f"--log-file={log}",
            str(target),
            workload["resolved_path"],
        ]
        expected_status = 0 if workload["classification"] == "benchmark-valid" else 2
        try:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=args.timeout,
                check=False,
            )
            observed: str | int = completed.returncode
            log_text = log.read_text(encoding="utf-8", errors="replace")
            error_match = re.search(r"ERROR SUMMARY: ([0-9,]+) errors", log_text)
            descriptor_match = re.search(r"FILE DESCRIPTORS: ([0-9]+) open", log_text)
            memcheck_errors = (
                int(error_match.group(1).replace(",", "")) if error_match else -1
            )
            open_fds = int(descriptor_match.group(1)) if descriptor_match else -1
            status_matches = completed.returncode == expected_status
            descriptors_clean = open_fds == 4
            verdict = (
                "pass"
                if status_matches and memcheck_errors == 0 and descriptors_clean
                else "fail"
            )
        except subprocess.TimeoutExpired:
            observed = "timeout"
            verdict = "error"
            memcheck_errors = -1
            open_fds = -1
        if verdict != "pass":
            had_error = True
        rows.append(
            {
                "target": target_name,
                "workload": workload_name,
                "classification": workload["classification"],
                "expected_status": expected_status,
                "observed_status": observed,
                "memcheck_errors": memcheck_errors,
                "open_fds_including_log": open_fds,
                "verdict": verdict,
                "log": log.name,
            }
        )
        print(f"{target_name}/{workload_name}: {verdict}")
    with results_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)
    return 1 if had_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
