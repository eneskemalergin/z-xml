#!/usr/bin/env python3
"""Qualify declared event adapters against a generated XML corpus."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

MAX_WORKLOAD_BYTES = 1024 * 1024 * 1024
CORPUS_SCHEMA = "z-xml-generated-v3"
TARGET_SCHEMAS = {"z-xml-targets-v1", "z-xml-targets-v2"}
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
MANIFEST_COLUMNS = [
    "id",
    "path",
    "shape",
    "target_bytes",
    "actual_bytes",
    "classification",
    "feature_checks",
    "rejection_fraction",
    "fatal_offset",
    "fatal_fraction",
    "elements",
    "attributes",
    "normalized_text_bytes",
    "expected_summary",
]
EXPECTED_SUMMARY_FIELDS = {"elements", "attributes", "text_bytes", "checksum"}
PROCESSOR_CLASSES = {"wf", "partial", "subset", "lexical", "index", "validating"}
WORK_LANES = {"event", "dom", "subset", "lexical", "structural-index", "validated"}
INPUT_MODELS = {"streaming-reader", "file-reader", "whole-file"}
EVENT_PROCESSOR_CLASSES = {"wf", "partial"}


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
    parser.add_argument("--max-bytes", type=int, default=MAX_WORKLOAD_BYTES)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--address-space-mib", type=int, default=2048)
    parser.add_argument("--cpu-seconds", type=int, default=30)
    parser.add_argument("--open-files", type=int, default=64)
    parser.add_argument("--max-output-bytes", type=int, default=64 * 1024)
    return parser.parse_args()


def result_path(args: argparse.Namespace) -> Path:
    resolved = args.results.resolve()
    manifest = args.manifest.resolve()
    targets = args.targets.resolve()
    corpus_root = args.manifest.parent.resolve()
    bin_root = args.bin_dir.resolve()
    if (
        args.results.is_symlink()
        or resolved in {manifest, targets}
        or resolved.is_relative_to(corpus_root)
        or resolved.is_relative_to(bin_root)
    ):
        raise ValueError("result path overlaps a checker input")
    return resolved


def decode_json(value: str | bytes) -> object:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        decoded: dict[str, object] = {}
        for key, item in pairs:
            if key in decoded:
                raise ValueError(f"duplicate JSON field: {key}")
            decoded[key] = item
        return decoded

    return json.loads(value, object_pairs_hook=unique_object)


def read_targets(path: Path, bin_dir: Path, selected: set[str]) -> list[Target]:
    with path.open(encoding="utf-8") as stream:
        lines = list(stream)
    if len(lines) < 3:
        raise ValueError(f"{path}: empty target manifest")
    schema = lines[0].removeprefix("#").strip()
    if schema not in TARGET_SCHEMAS:
        raise ValueError(f"{path}: unsupported target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{path}: invalid target header")

    bin_root = bin_dir.resolve()
    targets: list[Target] = []
    seen: set[str] = set()
    for line_number, line in enumerate(lines[2:], 3):
        if not line.strip():
            continue
        if line.startswith("#"):
            raise ValueError(f"{path}:{line_number}: unexpected comment")
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 6 or any(not field for field in fields):
            raise ValueError(f"{path}:{line_number}: invalid target row")
        name, executable, processor_class, features_text, work_lane, input_model = (
            fields
        )
        if name in seen:
            raise ValueError(f"{path}:{line_number}: duplicate target {name}")
        seen.add(name)
        features = features_text.split(",")
        if any(not feature for feature in features) or len(features) != len(
            set(features)
        ):
            raise ValueError(f"{path}:{line_number}: invalid target features")
        if (
            processor_class not in PROCESSOR_CLASSES
            or work_lane not in WORK_LANES
            or input_model not in INPUT_MODELS
        ):
            raise ValueError(f"{path}:{line_number}: invalid target declaration")
        if selected and name not in selected:
            continue
        if processor_class not in EVENT_PROCESSOR_CLASSES or work_lane != "event":
            if selected:
                raise ValueError(f"{name}: target does not declare an event input lane")
            continue
        program = (bin_root / executable).resolve()
        try:
            program.relative_to(bin_root)
        except ValueError as error:
            raise ValueError(
                f"{name}: executable escapes the binary directory"
            ) from error
        if not program.is_file() or not os.access(program, os.X_OK):
            raise ValueError(f"missing executable for {name}: {program}")
        targets.append(
            Target(
                name=name,
                executable=program,
                processor_class=processor_class,
                features=frozenset(features),
                work_lane=work_lane,
                input_model=input_model,
            )
        )
    unknown = selected.difference(seen)
    if unknown:
        raise ValueError("unknown targets: " + ",".join(sorted(unknown)))
    if not targets:
        raise ValueError(f"{path}: no event targets selected")
    return targets


def read_workloads(manifest: Path, max_bytes: int) -> list[dict[str, str]]:
    with manifest.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    comments = [line[1:].strip() for line in lines if line.startswith("#")]
    expected_comments = [
        CORPUS_SCHEMA,
        f"size ceiling: {MAX_WORKLOAD_BYTES} bytes",
    ]
    if comments != expected_comments:
        raise ValueError(f"{manifest}: invalid generated-corpus identity")
    reader = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    if reader.fieldnames != MANIFEST_COLUMNS:
        raise ValueError(f"{manifest}: invalid generated-corpus columns")
    rows = list(reader)
    if not rows:
        raise ValueError(f"{manifest}: generated manifest is empty")

    root = manifest.parent.resolve()
    selected_rows: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    seen_paths: set[Path] = set()
    for line_number, row in enumerate(rows, 4):
        if None in row or any(value is None or value == "" for value in row.values()):
            raise ValueError(f"{manifest}:{line_number}: invalid workload row")
        item_id = row["id"]
        if item_id in seen_ids:
            raise ValueError(
                f"{manifest}:{line_number}: duplicate workload ID {item_id}"
            )
        seen_ids.add(item_id)
        path = (root / row["path"]).resolve()
        try:
            path.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{item_id}: path escapes generated corpus") from error
        if path in seen_paths:
            raise ValueError(f"{item_id}: duplicate workload path")
        seen_paths.add(path)
        try:
            actual_bytes = int(row["actual_bytes"])
            target_bytes = int(row["target_bytes"])
        except ValueError as error:
            raise ValueError(f"{item_id}: invalid workload size") from error
        if actual_bytes <= 0 or target_bytes < 0:
            raise ValueError(f"{item_id}: invalid workload size")
        try:
            size = path.stat().st_size
        except OSError as error:
            raise ValueError(f"{item_id}: {error}") from error
        if (
            not path.is_file()
            or size != actual_bytes
            or (target_bytes and size != target_bytes)
        ):
            raise ValueError(f"{item_id}: byte size differs from manifest")
        if size > MAX_WORKLOAD_BYTES:
            raise ValueError(f"{item_id}: exceeds the 1 GiB workload ceiling")
        features = row["feature_checks"].split(",")
        if any(not feature for feature in features) or len(features) != len(
            set(features)
        ):
            raise ValueError(f"{item_id}: invalid feature checks")
        if row["classification"] == "benchmark-valid":
            if any(
                row[field] != "-"
                for field in ("rejection_fraction", "fatal_offset", "fatal_fraction")
            ):
                raise ValueError(f"{item_id}: valid workload has rejection metadata")
            try:
                expected = decode_json(row["expected_summary"])
                declared_counts = (
                    int(row["elements"]),
                    int(row["attributes"]),
                    int(row["normalized_text_bytes"]),
                )
            except ValueError as error:
                raise ValueError(f"{item_id}: invalid expected summary") from error
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
                or declared_counts
                != (
                    expected["elements"],
                    expected["attributes"],
                    expected["text_bytes"],
                )
            ):
                raise ValueError(f"{item_id}: summary columns disagree")
        elif row["classification"] == "not-well-formed":
            if (
                row["shape"] != "rejection"
                or row["expected_summary"] != "-"
                or any(
                    row[field] != "-"
                    for field in ("elements", "attributes", "normalized_text_bytes")
                )
            ):
                raise ValueError(f"{item_id}: invalid rejection metadata")
            try:
                requested_fraction = int(row["rejection_fraction"])
                fatal_offset = int(row["fatal_offset"])
                declared_fraction = float(row["fatal_fraction"])
            except ValueError as error:
                raise ValueError(f"{item_id}: invalid rejection position") from error
            actual_fraction = fatal_offset * 100 / size
            if (
                not math.isfinite(declared_fraction)
                or requested_fraction < 1
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
        if size <= max_bytes:
            row["resolved_path"] = str(path)
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
        f"--fsize={args.max_output_bytes}",
        "--",
        str(target.executable),
        workload["resolved_path"],
    ]
    try:
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                timeout=args.timeout,
                check=False,
            )
            stdout.seek(0)
            output = stdout.read(args.max_output_bytes + 1)
            stderr.seek(0)
            diagnostic = stderr.read(args.max_output_bytes + 1)
    except subprocess.TimeoutExpired:
        return "timeout", "timeout"
    except OSError as error:
        return "error-exec", str(error)
    if len(output) > args.max_output_bytes or len(diagnostic) > args.max_output_bytes:
        return "error-output", "output-limit"
    if completed.returncode in {-signal.SIGXFSZ, 128 + signal.SIGXFSZ}:
        return "error-output", "output-limit"
    if completed.returncode == 2:
        return "reject", "-"
    if completed.returncode == 3:
        return "resource-limit", "adapter-limit"
    if completed.returncode != 0:
        return f"error-{completed.returncode}", f"status-{completed.returncode}"
    if workload["classification"] == "not-well-formed":
        return "accept", "-"
    try:
        observed = decode_json(output)
        expected = decode_json(workload["expected_summary"])
    except (UnicodeDecodeError, ValueError):
        return "error-output", "invalid-json"
    if not isinstance(observed, dict) or set(observed) != EXPECTED_SUMMARY_FIELDS:
        return "error-output", "unexpected-fields"
    if any(
        type(observed[field]) is not int or observed[field] < 0
        for field in ("elements", "attributes", "text_bytes")
    ):
        return "error-output", "invalid-summary-values"
    checksum = observed["checksum"]
    if not isinstance(checksum, str) or len(checksum) != 16:
        return "error-output", "invalid-summary-values"
    try:
        checksum_value = int(checksum, 16)
    except ValueError:
        return "error-output", "invalid-summary-values"
    if checksum_value > 0xFFFFFFFFFFFFFFFF:
        return "error-output", "invalid-summary-values"
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
        or args.max_output_bytes <= 0
        or args.timeout <= 0
        or not math.isfinite(args.timeout)
        or args.max_bytes <= 0
        or args.max_bytes > MAX_WORKLOAD_BYTES
        or len(args.target) != len(set(args.target))
    ):
        print("invalid limits, timeout, or target selection", file=sys.stderr)
        return 64
    limit_probe = subprocess.run(
        [
            "prlimit",
            f"--as={args.address_space_mib * 1024 * 1024}",
            f"--cpu={args.cpu_seconds}",
            f"--nofile={args.open_files}",
            f"--fsize={args.max_output_bytes}",
            "--",
            "true",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if limit_probe.returncode != 0:
        print("could not apply generated-corpus process limits", file=sys.stderr)
        return 1
    try:
        results = result_path(args)
        results.parent.mkdir(parents=True, exist_ok=True)
        results.unlink(missing_ok=True)
        targets = read_targets(args.targets, args.bin_dir, set(args.target))
        workloads = read_workloads(args.manifest, args.max_bytes)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

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
    target_passes: Counter[str] = Counter()
    failure_reasons: Counter[str] = Counter()
    temporary_path: Path | None = None
    failed = True
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            newline="",
            dir=results.parent,
            prefix=results.name + ".",
            suffix=".tmp",
            delete=False,
        ) as stream:
            temporary_path = Path(stream.name)
            writer = csv.DictWriter(
                stream, fieldnames=fieldnames, delimiter="\t", lineterminator="\n"
            )
            writer.writeheader()
            for target in targets:
                counts: Counter[str] = Counter()
                for workload in workloads:
                    required = set(workload["feature_checks"].split(","))
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
                            target_passes[target.name] += 1
                        elif observed in {"accept", "reject", "accept-mismatch"}:
                            verdict = "fail"
                        else:
                            verdict = "error"
                    counts[verdict] += 1
                    totals[verdict] += 1
                    if verdict in {"fail", "error"}:
                        failure_reasons[reason] += 1
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
                    f"{target.name}: pass={counts['pass']} fail={counts['fail']} "
                    f"unsupported={counts['unsupported-feature']} error={counts['error']}"
                )
        missing_passes = [
            target.name for target in targets if not target_passes[target.name]
        ]
        failed = bool(totals["fail"] or totals["error"] or missing_passes)
        if missing_passes:
            print(
                "targets with no qualified workload: " + ",".join(missing_passes),
                file=sys.stderr,
            )
        if failed:
            temporary_path.unlink(missing_ok=True)
        else:
            temporary_path.replace(results)
    except OSError as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        print(error, file=sys.stderr)
        return 1
    print(
        f"total: pass={totals['pass']} fail={totals['fail']} "
        f"unsupported={totals['unsupported-feature']} error={totals['error']}"
    )
    for reason, count in sorted(failure_reasons.items()):
        print(f"failure {reason}: {count}", file=sys.stderr)
    if failed:
        print("results not published", file=sys.stderr)
        return 1
    print(f"results: {results}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
