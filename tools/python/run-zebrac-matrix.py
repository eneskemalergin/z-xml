#!/usr/bin/env python3
"""Run correctness-qualified zebrac comparisons in separate work lanes."""

from __future__ import annotations

import argparse
import csv
import fnmatch
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SCHEMAS = {"z-xml-generated-v2", "z-xml-generated-v3"}
MAX_WORKLOAD_BYTES = 1024 * 1024 * 1024
ELIGIBILITY_FIELDS = {"target", "workload", "verdict"}


@dataclass(frozen=True)
class Target:
    name: str
    executable: Path
    processor_class: str
    work_lane: str
    input_model: str


def resolve_zebrac(explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit.resolve()
    command = shutil.which("zebrac")
    return Path(command).resolve() if command is not None else None


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--eligibility", type=Path, action="append", required=True)
    parser.add_argument("--targets", type=Path, default=root / "ref" / "targets.tsv")
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument(
        "--zebrac",
        type=Path,
        help="Zebrac executable (default: resolve zebrac from PATH)",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--workload", action="append", required=True, help="Workload ID or glob"
    )
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--lane", action="append", default=[])
    parser.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--duration-ms", type=int, default=5000)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def read_targets(path: Path, bin_dir: Path) -> dict[str, Target]:
    targets: dict[str, Target] = {}
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 6:
                raise ValueError(f"{path}:{line_number}: expected 6 fields")
            name, executable, processor_class, _features, work_lane, input_model = (
                fields
            )
            if name in targets:
                raise ValueError(f"{path}:{line_number}: duplicate target {name}")
            targets[name] = Target(
                name=name,
                executable=(bin_dir / executable).resolve(),
                processor_class=processor_class,
                work_lane=work_lane,
                input_model=input_model,
            )
    return targets


def read_workloads(path: Path) -> dict[str, dict[str, str]]:
    root = path.parent.resolve()
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    comments = {line[1:].strip() for line in lines if line.startswith("#")}
    if not SCHEMAS.intersection(comments):
        raise ValueError(f"{path}: unsupported generated-corpus schema")
    if f"size ceiling: {MAX_WORKLOAD_BYTES} bytes" not in comments:
        raise ValueError(f"{path}: unexpected workload ceiling")
    workloads: dict[str, dict[str, str]] = {}
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    required = {
        "id",
        "path",
        "target_bytes",
        "actual_bytes",
        "classification",
    }
    if rows.fieldnames is None or required.difference(rows.fieldnames):
        raise ValueError(f"{path}: incomplete generated manifest")
    for row in rows:
        if row["id"] in workloads:
            raise ValueError(f"{path}: duplicate workload ID {row['id']}")
        workloads[row["id"]] = row
    if not workloads:
        raise ValueError(f"{path}: empty manifest")
    seen_paths: set[Path] = set()
    for workload in workloads.values():
        resolved = (root / workload["path"]).resolve()
        try:
            resolved.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{workload['id']}: path escapes corpus") from error
        if not resolved.is_file():
            raise ValueError(f"{workload['id']}: missing {resolved}")
        if resolved in seen_paths:
            raise ValueError(f"{workload['id']}: duplicate workload path")
        seen_paths.add(resolved)
        actual = resolved.stat().st_size
        manifest_size = int(workload["actual_bytes"])
        target_size = int(workload["target_bytes"])
        if actual != manifest_size:
            raise ValueError(f"{workload['id']}: size differs from manifest")
        if target_size and actual != target_size:
            raise ValueError(f"{workload['id']}: size differs from target")
        if actual > MAX_WORKLOAD_BYTES:
            raise ValueError(f"{workload['id']}: exceeds the 1 GiB ceiling")
        if workload["classification"] not in {"benchmark-valid", "not-well-formed"}:
            raise ValueError(f"{workload['id']}: unsupported classification")
        workload["resolved_path"] = str(resolved)
    return workloads


def read_eligibility(path: Path) -> dict[tuple[str, str], str]:
    verdicts: dict[tuple[str, str], str] = {}
    with path.open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames is None or ELIGIBILITY_FIELDS.difference(reader.fieldnames):
            raise ValueError(f"{path}: incomplete eligibility report")
        for line_number, row in enumerate(reader, 2):
            target = row.get("target", "")
            workload = row.get("workload", "")
            verdict = row.get("verdict", "")
            if not target or not workload or not verdict:
                raise ValueError(f"{path}:{line_number}: incomplete eligibility row")
            pair = (target, workload)
            if pair in verdicts:
                raise ValueError(
                    f"{path}:{line_number}: duplicate eligibility for "
                    f"{target}/{workload}"
                )
            verdicts[pair] = verdict
    return verdicts


def validate_zebrac_results(
    path: Path,
    commands: list[str],
    classification: str,
    samples: int,
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
        return "zebrac result count differs from target count"
    expected_failures = classification == "not-well-formed"
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
        if expected_failures and failed_sample_count != sample_count:
            return f"expected every malformed sample to fail at index {index}"
        if not expected_failures and failed_sample_count != 0:
            return f"valid workload has failed zebrac samples at index {index}"
    return None


def safe_name(value: str) -> str:
    return "".join(
        character if character.isalnum() or character in "-_" else "_"
        for character in value
    )


def host_information() -> dict[str, object]:
    cpu_model = "unknown"
    memory_kib = 0
    try:
        with Path("/proc/cpuinfo").open(encoding="utf-8") as stream:
            for line in stream:
                if line.startswith("model name"):
                    cpu_model = line.partition(":")[2].strip()
                    break
    except OSError:
        pass
    try:
        with Path("/proc/meminfo").open(encoding="utf-8") as stream:
            for line in stream:
                if line.startswith("MemTotal:"):
                    memory_kib = int(line.split()[1])
                    break
    except (OSError, ValueError):
        pass
    libc_name, libc_version = platform.libc_ver()
    return {
        "system": platform.system(),
        "kernel": platform.release(),
        "machine": platform.machine(),
        "cpu_model": cpu_model,
        "logical_cpu_count": os.cpu_count(),
        "memory_kib": memory_kib,
        "libc": libc_name,
        "libc_version": libc_version,
    }


def main() -> int:
    args = parse_args()
    if (
        args.max_bytes <= 0
        or args.duration_ms <= 0
        or args.samples <= 0
        or args.warmups < 0
    ):
        print(
            "numeric limits must be positive, except warmups may be zero",
            file=sys.stderr,
        )
        return 64
    try:
        targets = read_targets(args.targets, args.bin_dir.resolve())
        workloads = read_workloads(args.manifest)
        verdicts: dict[tuple[str, str], str] = {}
        for eligibility_path in args.eligibility:
            verdicts.update(read_eligibility(eligibility_path))
        passing = {pair for pair, verdict in verdicts.items() if verdict == "pass"}
    except (OSError, KeyError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    selected_targets = set(args.target) if args.target else set(targets)
    unknown_targets = selected_targets.difference(targets)
    if unknown_targets:
        print("unknown targets: " + ",".join(sorted(unknown_targets)), file=sys.stderr)
        return 64
    selected_lanes = set(args.lane)
    matched_workloads = [
        workload
        for workload in workloads.values()
        if any(
            fnmatch.fnmatchcase(workload["id"], pattern) for pattern in args.workload
        )
    ]
    if not matched_workloads:
        print("workload patterns matched nothing", file=sys.stderr)
        return 64

    groups: list[dict[str, object]] = []
    skipped: list[dict[str, str]] = []
    ineligible: list[dict[str, str]] = []
    for workload in matched_workloads:
        size = int(workload["actual_bytes"])
        if size > args.max_bytes:
            skipped.append({"workload": workload["id"], "reason": "max-bytes"})
            continue
        lanes = sorted({target.work_lane for target in targets.values()})
        for lane in lanes:
            if selected_lanes and lane not in selected_lanes:
                continue
            candidates = [
                target
                for target in targets.values()
                if target.name in selected_targets and target.work_lane == lane
            ]
            eligible = [
                target
                for target in candidates
                if (target.name, workload["id"]) in passing
            ]
            for target in candidates:
                pair = (target.name, workload["id"])
                if pair not in passing:
                    ineligible.append(
                        {
                            "target": target.name,
                            "workload": workload["id"],
                            "lane": lane,
                            "verdict": verdicts.get(pair, "missing-eligibility"),
                        }
                    )
            if not eligible:
                continue
            missing = [
                str(target.executable)
                for target in eligible
                if not target.executable.is_file()
            ]
            if missing:
                print(
                    "missing benchmark executables: " + ",".join(missing),
                    file=sys.stderr,
                )
                return 1
            commands = [
                shlex.join([str(target.executable), workload["resolved_path"]])
                for target in eligible
            ]
            groups.append(
                {
                    "workload": workload,
                    "lane": lane,
                    "targets": eligible,
                    "commands": commands,
                }
            )
    if not groups:
        print(
            "no correctness-passing target/workload groups were selected",
            file=sys.stderr,
        )
        return 1

    if args.dry_run:
        for group in groups:
            print(f"{group['workload']['id']} [{group['lane']}]")
            for target, command in zip(
                group["targets"], group["commands"], strict=True
            ):
                print(f"  {target.name}: {command}")
        for item in skipped:
            print(f"skip {item['workload']}: {item['reason']}")
        for item in ineligible:
            print(
                f"ineligible {item['target']}/{item['workload']} "
                f"[{item['lane']}]: {item['verdict']}"
            )
        return 0

    zebrac = resolve_zebrac(args.zebrac)
    if zebrac is None:
        print("zebrac not found on PATH; pass --zebrac PATH", file=sys.stderr)
        return 1
    if not zebrac.is_file():
        print(f"missing zebrac binary: {zebrac}", file=sys.stderr)
        return 1
    args.output_dir.mkdir(parents=True, exist_ok=True)
    version = subprocess.run(
        [zebrac, "--version"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if version.returncode != 0:
        print("unable to query zebrac version", file=sys.stderr)
        return 1
    version_text = version.stdout.strip()
    profile_stamp = (
        args.bin_dir.resolve().parent.parent
        / "build"
        / args.bin_dir.resolve().name
        / ".release-profile"
    )
    participating_targets = {
        target.name for group in groups for target in group["targets"]
    }
    selected_binary_metadata = {
        target.name: {
            "path": str(target.executable),
            "size": target.executable.stat().st_size,
            "lane": target.work_lane,
            "input_model": target.input_model,
        }
        for target in targets.values()
        if target.name in participating_targets and target.executable.is_file()
    }
    index: dict[str, object] = {
        "schema": "z-xml-zebrac-matrix-v2",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "manifest": str(args.manifest.resolve()),
        "eligibility": [str(path.resolve()) for path in args.eligibility],
        "bin_dir": str(args.bin_dir.resolve()),
        "zebrac": str(zebrac),
        "zebrac_version": version_text,
        "targets_manifest": str(args.targets.resolve()),
        "build_profile": profile_stamp.read_text(encoding="utf-8")
        if profile_stamp.is_file()
        else None,
        "host": host_information(),
        "target_binaries": selected_binary_metadata,
        "sampling": {
            "duration_ms": args.duration_ms,
            "samples": args.samples,
            "warmups": args.warmups,
        },
        "runs": [],
        "skipped": skipped,
        "ineligible": ineligible,
    }
    had_error = False
    for group in groups:
        workload = group["workload"]
        lane = str(group["lane"])
        stem = safe_name(f"{workload['id']}--{lane}")
        json_path = args.output_dir / f"{stem}.json"
        command = [
            str(zebrac),
            "--quiet",
            "--duration",
            str(args.duration_ms),
            "--min-samples",
            str(args.samples),
            "--max-samples",
            str(args.samples),
            "--warmup",
            str(args.warmups),
            f"--json={json_path}",
        ]
        if workload["classification"] == "not-well-formed":
            command.append("--allow-failures")
        command.append("--")
        command.extend(group["commands"])
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        stdout_path = args.output_dir / f"{stem}.stdout.txt"
        stderr_path = args.output_dir / f"{stem}.stderr.txt"
        stdout_path.write_text(completed.stdout, encoding="utf-8")
        stderr_path.write_text(completed.stderr, encoding="utf-8")
        run = {
            "workload": workload["id"],
            "bytes": int(workload["actual_bytes"]),
            "classification": workload["classification"],
            "lane": lane,
            "targets": [target.name for target in group["targets"]],
            "input_models": [target.input_model for target in group["targets"]],
            "commands": group["commands"],
            "zebrac_json": json_path.name,
            "stdout": stdout_path.name,
            "stderr": stderr_path.name,
            "status": completed.returncode,
        }
        index["runs"].append(run)
        result_error = None
        if completed.returncode == 0:
            result_error = validate_zebrac_results(
                json_path,
                group["commands"],
                workload["classification"],
                args.samples,
            )
        if completed.returncode != 0 or result_error is not None:
            had_error = True
            reason = result_error or f"status-{completed.returncode}"
            print(
                f"zebrac failed for {workload['id']} [{lane}]: {reason}",
                file=sys.stderr,
            )
        else:
            print(f"measured {workload['id']} [{lane}]")
    temporary = args.output_dir / "index.json.tmp"
    temporary.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.output_dir / "index.json")
    return 1 if had_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
