#!/usr/bin/env python3
"""Check generated XML bytes, parser outcomes, and common summaries."""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

MAX_WORKLOAD_BYTES = 1024 * 1024 * 1024
SCHEMAS = {"z-xml-generated-v2", "z-xml-generated-v3"}
EXPECTED_SUMMARY_FIELDS = {"elements", "attributes", "text_bytes", "checksum"}


@dataclass(frozen=True)
class Target:
    name: str
    executable: Path
    processor_class: str
    features: frozenset[str]
    work_lane: str
    input_model: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--max-bytes", type=int, default=1024 * 1024 * 1024)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--address-space-mib", type=int, default=2048)
    parser.add_argument("--cpu-seconds", type=int, default=30)
    parser.add_argument("--open-files", type=int, default=64)
    return parser.parse_args()


def read_targets(path: Path, bin_dir: Path, selected: set[str]) -> list[Target]:
    targets: list[Target] = []
    seen: set[str] = set()
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 6:
                raise ValueError(
                    f"{path}:{line_number}: expected 6 tab-separated fields"
                )
            name, executable, processor_class, features, work_lane, input_model = fields
            if name in seen:
                raise ValueError(f"{path}:{line_number}: duplicate target {name}")
            seen.add(name)
            if selected and name not in selected:
                continue
            program = (bin_dir / executable).resolve()
            if not program.is_file():
                raise ValueError(f"missing executable for {name}: {program}")
            targets.append(
                Target(
                    name=name,
                    executable=program,
                    processor_class=processor_class,
                    features=frozenset(features.split(",")),
                    work_lane=work_lane,
                    input_model=input_model,
                )
            )
    if selected.difference(seen):
        raise ValueError(
            "unknown targets: " + ",".join(sorted(selected.difference(seen)))
        )
    return targets


def read_workloads(manifest: Path, max_bytes: int) -> list[dict[str, str]]:
    with manifest.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    comments = {line[1:].strip() for line in lines if line.startswith("#")}
    if not SCHEMAS.intersection(comments):
        raise ValueError(f"{manifest}: unsupported generated-corpus schema")
    if f"size ceiling: {MAX_WORKLOAD_BYTES} bytes" not in comments:
        raise ValueError(f"{manifest}: unexpected workload ceiling")
    rows = list(
        csv.DictReader(
            (line for line in lines if not line.startswith("#")), delimiter="\t"
        )
    )
    required = {
        "id",
        "path",
        "shape",
        "target_bytes",
        "classification",
        "feature_checks",
        "actual_bytes",
        "rejection_fraction",
        "fatal_offset",
        "fatal_fraction",
        "elements",
        "attributes",
        "normalized_text_bytes",
        "expected_summary",
    }
    if not rows:
        raise ValueError(f"{manifest}: generated manifest is empty")
    missing = required.difference(rows[0])
    if missing:
        raise ValueError(f"{manifest}: missing fields: {','.join(sorted(missing))}")
    seen: set[str] = set()
    seen_paths: set[str] = set()
    root = manifest.parent.resolve()
    selected_rows: list[dict[str, str]] = []
    for row in rows:
        item_id = row["id"]
        if item_id in seen:
            raise ValueError(f"{manifest}: duplicate workload ID {item_id}")
        seen.add(item_id)
        if row["path"] in seen_paths:
            raise ValueError(f"{manifest}: duplicate workload path {row['path']}")
        seen_paths.add(row["path"])
        if int(row["actual_bytes"]) > max_bytes:
            continue
        path = (root / row["path"]).resolve()
        try:
            path.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{item_id}: path escapes generated corpus") from error
        try:
            size = path.stat().st_size
        except OSError as error:
            raise ValueError(f"{item_id}: {error}") from error
        if size != int(row["actual_bytes"]):
            raise ValueError(f"{item_id}: byte size differs from manifest")
        target_bytes = int(row.get("target_bytes", "0"))
        if target_bytes and size != target_bytes:
            raise ValueError(f"{item_id}: byte size differs from target")
        if size > MAX_WORKLOAD_BYTES:
            raise ValueError(f"{item_id}: exceeds the 1 GiB workload ceiling")
        row["resolved_path"] = str(path)
        if row["classification"] == "benchmark-valid":
            if any(
                row[field] != "-"
                for field in ("rejection_fraction", "fatal_offset", "fatal_fraction")
            ):
                raise ValueError(f"{item_id}: valid workload has rejection metadata")
            try:
                expected = json.loads(row["expected_summary"])
            except json.JSONDecodeError as error:
                raise ValueError(f"{item_id}: invalid expected summary JSON") from error
            if (
                not isinstance(expected, dict)
                or set(expected) != EXPECTED_SUMMARY_FIELDS
            ):
                raise ValueError(f"{item_id}: unexpected expected-summary fields")
            if (
                type(expected["elements"]) is not int
                or type(expected["attributes"]) is not int
                or type(expected["text_bytes"]) is not int
                or not isinstance(expected["checksum"], str)
                or len(expected["checksum"]) != 16
            ):
                raise ValueError(f"{item_id}: invalid expected-summary values")
            try:
                checksum = int(expected["checksum"], 16)
            except ValueError as error:
                raise ValueError(
                    f"{item_id}: invalid expected-summary checksum"
                ) from error
            if (
                min(
                    expected["elements"],
                    expected["attributes"],
                    expected["text_bytes"],
                    checksum,
                )
                < 0
                or checksum > 0xFFFFFFFFFFFFFFFF
                or int(row["elements"]) != expected["elements"]
                or int(row["attributes"]) != expected["attributes"]
                or int(row["normalized_text_bytes"]) != expected["text_bytes"]
            ):
                raise ValueError(f"{item_id}: summary columns disagree")
        elif row["classification"] == "not-well-formed":
            if row["shape"] != "rejection" or row["expected_summary"] != "-":
                raise ValueError(f"{item_id}: invalid rejection metadata")
            try:
                requested_fraction = int(row["rejection_fraction"])
                fatal_offset = int(row["fatal_offset"])
                declared_fraction = float(row["fatal_fraction"])
            except ValueError as error:
                raise ValueError(f"{item_id}: invalid rejection position") from error
            actual_fraction = fatal_offset * 100 / size
            if (
                requested_fraction < 1
                or requested_fraction > 99
                or fatal_offset < 0
                or fatal_offset + len(b"</bad>") > size
                or abs(declared_fraction - actual_fraction) > 0.000001
                or abs(actual_fraction - requested_fraction) > 0.01
            ):
                raise ValueError(f"{item_id}: rejection position disagrees")
            try:
                with path.open("rb") as input_stream:
                    input_stream.seek(fatal_offset)
                    fatal_construct = input_stream.read(len(b"</bad>"))
            except OSError as error:
                raise ValueError(f"{item_id}: {error}") from error
            if fatal_construct != b"</bad>":
                raise ValueError(f"{item_id}: fatal construct differs")
        else:
            raise ValueError(
                f"{item_id}: unsupported classification {row['classification']}"
            )
        selected_rows.append(row)
    if not selected_rows:
        raise ValueError(f"{manifest}: no workloads are at or below --max-bytes")
    return selected_rows


def observe(
    target: Target, workload: dict[str, str], args: argparse.Namespace
) -> tuple[str, str]:
    command = [
        "prlimit",
        f"--as={args.address_space_mib * 1024 * 1024}",
        f"--cpu={args.cpu_seconds}",
        f"--nofile={args.open_files}",
        "--",
        target.executable,
        workload["resolved_path"],
    ]
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=args.timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return "timeout", "timeout"
    except OSError as error:
        return "error-exec", str(error)
    if completed.returncode == 2:
        return "reject", "-"
    if completed.returncode == 3:
        return "resource-limit", "adapter-limit"
    if completed.returncode != 0:
        return f"error-{completed.returncode}", "adapter-status"
    if workload["classification"] == "not-well-formed":
        return "accept", "-"
    try:
        observed = json.loads(completed.stdout)
        expected = json.loads(workload["expected_summary"])
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "error-output", "invalid-json"
    if observed != expected:
        return "accept-mismatch", "summary-mismatch"
    return "accept", "-"


def main() -> int:
    args = parse_args()
    if shutil.which("prlimit") is None:
        print(
            "generated corpus check requires prlimit from util-linux", file=sys.stderr
        )
        return 1
    if (
        args.address_space_mib <= 0
        or args.cpu_seconds <= 0
        or args.open_files <= 0
        or args.timeout <= 0
        or args.max_bytes <= 0
    ):
        print("resource limits and timeout must be positive", file=sys.stderr)
        return 64
    limit_probe = subprocess.run(
        [
            "prlimit",
            f"--as={args.address_space_mib * 1024 * 1024}",
            f"--cpu={args.cpu_seconds}",
            f"--nofile={args.open_files}",
            "--",
            "true",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if limit_probe.returncode != 0:
        print(
            "could not apply configured generated-corpus process limits",
            file=sys.stderr,
        )
        return 1
    try:
        targets = read_targets(args.targets, args.bin_dir, set(args.target))
        workloads = read_workloads(args.manifest, args.max_bytes)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    args.results.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "target",
        "work_lane",
        "input_model",
        "workload",
        "classification",
        "expected",
        "observed",
        "verdict",
        "reason",
    ]
    totals: Counter[str] = Counter()
    with args.results.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=fieldnames, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        for target in targets:
            counts: Counter[str] = Counter()
            for workload in workloads:
                required = set(workload["feature_checks"].split(","))
                if target.processor_class in {"lexical", "index"} or (
                    target.processor_class == "validating" and "dtd" not in required
                ):
                    expected = "out-of-profile"
                    observed = "not-run"
                    verdict = "out-of-profile"
                    reason = "processor-profile"
                else:
                    missing = sorted(required.difference(target.features))
                    if missing:
                        expected = "unsupported-feature"
                        observed = "not-run"
                        verdict = "unsupported-feature"
                        reason = "missing:" + ",".join(missing)
                    else:
                        expected = (
                            "accept"
                            if workload["classification"] == "benchmark-valid"
                            else "reject"
                        )
                        observed, reason = observe(target, workload, args)
                        if observed == expected:
                            verdict = "pass"
                        elif observed == "resource-limit":
                            verdict = "resource-limit"
                        elif observed in {"accept", "reject", "accept-mismatch"}:
                            verdict = "fail"
                        else:
                            verdict = "error"
                counts[verdict] += 1
                totals[verdict] += 1
                writer.writerow(
                    {
                        "target": target.name,
                        "work_lane": target.work_lane,
                        "input_model": target.input_model,
                        "workload": workload["id"],
                        "classification": workload["classification"],
                        "expected": expected,
                        "observed": observed,
                        "verdict": verdict,
                        "reason": reason,
                    }
                )
            print(
                f"{target.name:<22} "
                f"applicable={counts['pass'] + counts['fail'] + counts['resource-limit']:<3} "
                f"pass={counts['pass']:<3} fail={counts['fail']:<3} "
                f"resource-limit={counts['resource-limit']:<3} "
                f"unsupported-feature={counts['unsupported-feature']:<3} "
                f"out-of-profile={counts['out-of-profile']:<3} error={counts['error']:<3}"
            )
    print(
        f"total: pass={totals['pass']} fail={totals['fail']} "
        f"resource-limit={totals['resource-limit']} "
        f"unsupported-feature={totals['unsupported-feature']} "
        f"out-of-profile={totals['out-of-profile']} error={totals['error']}"
    )
    print(f"results: {args.results}")
    return 1 if totals["fail"] or totals["error"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
