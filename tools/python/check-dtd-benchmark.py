#!/usr/bin/env python3
"""Qualify DTD benchmark commands against generated semantic and resource results."""

from __future__ import annotations

import argparse
import csv
import json
import os
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from qualification_io import decode_json_object, file_identity, read_limited

CORPUS_SCHEMA = "z-xml-dtd-generated-v1"
TARGET_SCHEMA = "z-xml-targets-v1"
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
MAX_OUTPUT_BYTES = 64 * 1024
MANIFEST_FIELDS = {
    "id",
    "path",
    "actual_bytes",
    "classification",
    "resource_paths",
    "targets",
    "program_args",
    "expected_status",
    "expected_result",
}
SEMANTIC_FIELDS = {
    "outcome",
    "error",
    "diagnostic",
    "source_id",
    "offset",
    "related_source_id",
    "related_offset",
    "inclusion_depth",
    "elements",
    "attributes",
    "defaulted_attributes",
    "text_bytes",
    "checksum",
    "content",
    "resolver_calls",
    "resolved_sources",
    "closed_sources",
    "unavailable_results",
    "failure_results",
    "external_subset_sources",
    "parameter_entity_sources",
    "general_entity_sources",
    "skipped_sources",
    "source_bytes",
}
MEMORY_FIELDS = {
    "allocator_operations",
    "requested_bytes",
    "peak_live_bytes",
    "dtd_capacity",
    "document_capacity",
    "retained_capacity",
    "live_bytes_before_deinit",
    "live_bytes_after_deinit",
    "caller_root_storage_bytes",
    "caller_external_peak_bytes",
    "caller_external_live_after_deinit",
}
RESULT_FIELDS = [
    "target",
    "workload",
    "classification",
    "verdict",
    "work_lane",
    "input_model",
    "program_args",
    "status",
    "dtd_capacity",
    "document_capacity",
    "retained_capacity",
    "peak_live_bytes",
    "allocator_operations",
    "caller_root_storage_bytes",
    "caller_external_peak_bytes",
    "live_bytes_after_deinit",
    "caller_external_live_after_deinit",
]


@dataclass(frozen=True)
class Target:
    name: str
    program: Path
    work_lane: str
    input_model: str


@dataclass(frozen=True)
class Workload:
    name: str
    source: Path
    resources: tuple[Path, ...]
    classification: str
    targets: tuple[str, ...]
    arguments: tuple[str, ...]
    expected_status: int
    expected_result: dict[str, object]


def read_targets(path: Path, bin_dir: Path) -> dict[str, Target]:
    lines = read_limited(path).decode("utf-8").splitlines()
    if len(lines) < 3 or lines[0].removeprefix("#").strip() != TARGET_SCHEMA:
        raise ValueError(f"{path}: unsupported target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{path}: invalid target header")
    root = bin_dir.resolve()
    targets: dict[str, Target] = {}
    for line_number, line in enumerate(lines[2:], 3):
        if not line or line.startswith("#"):
            raise ValueError(f"{path}:{line_number}: invalid target row")
        fields = line.split("\t")
        if len(fields) != 6 or any(not field for field in fields):
            raise ValueError(f"{path}:{line_number}: invalid target fields")
        name, executable, _processor, _features, work_lane, input_model = fields
        if name in targets:
            raise ValueError(f"{path}:{line_number}: duplicate target {name}")
        program = (root / executable).resolve()
        if not program.is_relative_to(root):
            raise ValueError(
                f"{path}:{line_number}: executable escapes the binary root"
            )
        targets[name] = Target(name, program, work_lane, input_model)
    return targets


def read_workloads(path: Path) -> list[Workload]:
    data = read_limited(path).decode("utf-8")
    lines = data.splitlines()
    if not lines or lines[0].removeprefix("#").strip() != CORPUS_SCHEMA:
        raise ValueError(f"{path}: unsupported corpus schema")
    reader = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    if reader.fieldnames is None or set(reader.fieldnames) != MANIFEST_FIELDS:
        raise ValueError(f"{path}: unexpected manifest columns")
    root = path.parent.resolve()
    workloads: list[Workload] = []
    names: set[str] = set()
    for line_number, row in enumerate(reader, 3):
        name = row["id"]
        if not name or name in names:
            raise ValueError(f"{path}:{line_number}: duplicate or empty workload")
        names.add(name)
        source = (root / row["path"]).resolve()
        if not source.is_relative_to(root) or not source.is_file():
            raise ValueError(f"{path}:{line_number}: invalid input path")
        if source.stat().st_size != int(row["actual_bytes"]):
            raise ValueError(f"{path}:{line_number}: input size differs")
        resource_values = (
            ()
            if row["resource_paths"] == "-"
            else tuple(row["resource_paths"].split(","))
        )
        if len(resource_values) != len(set(resource_values)):
            raise ValueError(f"{path}:{line_number}: duplicate resource path")
        resources: list[Path] = []
        for value in resource_values:
            resource = (root / value).resolve()
            if not resource.is_relative_to(root) or not resource.is_file():
                raise ValueError(f"{path}:{line_number}: invalid resource path")
            resources.append(resource)
        targets = tuple(row["targets"].split(","))
        arguments = tuple(row["program_args"].split())
        if (
            not targets
            or any(not value for value in targets)
            or len(targets) != len(set(targets))
            or not arguments
            or arguments[0] != "--dtd-report"
            or "--report-memory" in arguments
        ):
            raise ValueError(f"{path}:{line_number}: invalid command selection")
        expected_status = int(row["expected_status"])
        if expected_status not in {0, 1, 2, 3}:
            raise ValueError(f"{path}:{line_number}: invalid expected status")
        classification = row["classification"]
        if classification not in {"benchmark-valid", "not-well-formed"}:
            raise ValueError(f"{path}:{line_number}: invalid classification")
        expected_result = decode_json_object(row["expected_result"])
        if set(expected_result) != SEMANTIC_FIELDS:
            raise ValueError(f"{path}:{line_number}: invalid expected result fields")
        workloads.append(
            Workload(
                name,
                source,
                tuple(resources),
                classification,
                targets,
                arguments,
                expected_status,
                expected_result,
            )
        )
    if not workloads:
        raise ValueError(f"{path}: empty corpus")
    return workloads


def run_command(command: list[str], timeout: float) -> tuple[int, str, str, bool, bool]:
    with (
        tempfile.TemporaryFile() as stdout_file,
        tempfile.TemporaryFile() as stderr_file,
    ):
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            start_new_session=True,
        )
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        except KeyboardInterrupt:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout = stdout_file.read(MAX_OUTPUT_BYTES + 1)
        stderr = stderr_file.read(MAX_OUTPUT_BYTES + 1)
    overflow = len(stdout) > MAX_OUTPUT_BYTES or len(stderr) > MAX_OUTPUT_BYTES
    return (
        process.returncode,
        stdout[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace"),
        stderr[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace"),
        timed_out,
        overflow,
    )


def check_result(
    workload: Workload,
    completed: tuple[int, str, str, bool, bool],
    memory: bool,
) -> tuple[dict[str, object] | None, str | None]:
    status, stdout, stderr, timed_out, overflow = completed
    if timed_out:
        return None, "timeout"
    if overflow:
        return None, "output-limit"
    if status != workload.expected_status:
        return None, f"status-{status}"
    if stderr:
        return None, "unexpected-stderr"
    try:
        observed = decode_json_object(stdout)
    except (TypeError, ValueError, json.JSONDecodeError):
        return None, "invalid-json"
    expected_fields = SEMANTIC_FIELDS | (MEMORY_FIELDS if memory else set())
    if set(observed) != expected_fields:
        return None, "result-fields"
    semantic = {field: observed[field] for field in SEMANTIC_FIELDS}
    if semantic != workload.expected_result:
        return None, "semantic-mismatch"
    if not memory:
        return observed, None
    if any(
        type(observed[field]) is not int or observed[field] < 0
        for field in MEMORY_FIELDS
    ):
        return None, "memory-values"
    if (
        observed["retained_capacity"]
        != observed["dtd_capacity"] + observed["document_capacity"]
        or observed["live_bytes_after_deinit"] != 0
        or observed["caller_external_live_after_deinit"] != 0
        or observed["caller_root_storage_bytes"] != 64 * 1024
    ):
        return None, "memory-contract"
    return observed, None


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--targets", type=Path, default=root / "tools" / "dtd-targets.tsv"
    )
    parser.add_argument(
        "--bin-dir", type=Path, default=root / "tools" / "zig-out" / "bin"
    )
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=120.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.timeout <= 0:
        print("timeout must be positive", file=sys.stderr)
        return 64
    manifest = args.manifest.resolve()
    targets_path = args.targets.resolve()
    results = args.results.resolve()
    try:
        targets = read_targets(targets_path, args.bin_dir)
        workloads = read_workloads(manifest)
        input_paths = {
            manifest,
            targets_path,
            *(target.program for target in targets.values()),
            *(workload.source for workload in workloads),
            *(resource for workload in workloads for resource in workload.resources),
        }
        if (
            results in {manifest, targets_path}
            or results.is_relative_to(manifest.parent)
            or results in input_paths
            or results.with_name(results.name + ".tmp") in input_paths
        ):
            raise ValueError("result path overlaps an input")
        for target in targets.values():
            if not target.program.is_file() or not os.access(target.program, os.X_OK):
                raise ValueError(f"missing executable: {target.program}")
        input_identities = {path: file_identity(path) for path in input_paths}
        rows: list[dict[str, object]] = []
        errors: list[str] = []
        for workload in workloads:
            for target_name in workload.targets:
                target = targets.get(target_name)
                if target is None:
                    errors.append(f"{workload.name}/{target_name}: unknown-target")
                    continue
                command = [
                    str(target.program),
                    *workload.arguments,
                    str(workload.source),
                ]
                _, reason = check_result(
                    workload, run_command(command, args.timeout), False
                )
                memory_command = [
                    str(target.program),
                    *workload.arguments,
                    "--report-memory",
                    str(workload.source),
                ]
                memory, memory_reason = check_result(
                    workload, run_command(memory_command, args.timeout), True
                )
                reason = reason or memory_reason
                if reason is not None or memory is None:
                    errors.append(f"{workload.name}/{target_name}: {reason}")
                    continue
                rows.append(
                    {
                        "target": target.name,
                        "workload": workload.name,
                        "classification": workload.classification,
                        "verdict": "pass",
                        "work_lane": target.work_lane,
                        "input_model": target.input_model,
                        "program_args": " ".join(workload.arguments),
                        "status": workload.expected_status,
                        "dtd_capacity": memory["dtd_capacity"],
                        "document_capacity": memory["document_capacity"],
                        "retained_capacity": memory["retained_capacity"],
                        "peak_live_bytes": memory["peak_live_bytes"],
                        "allocator_operations": memory["allocator_operations"],
                        "caller_root_storage_bytes": memory[
                            "caller_root_storage_bytes"
                        ],
                        "caller_external_peak_bytes": memory[
                            "caller_external_peak_bytes"
                        ],
                        "live_bytes_after_deinit": memory["live_bytes_after_deinit"],
                        "caller_external_live_after_deinit": memory[
                            "caller_external_live_after_deinit"
                        ],
                    }
                )
        if errors:
            results.unlink(missing_ok=True)
            raise ValueError("\n".join(errors))
        for path, identity in input_identities.items():
            if file_identity(path) != identity:
                results.unlink(missing_ok=True)
                raise ValueError(f"input changed during qualification: {path}")
        results.parent.mkdir(parents=True, exist_ok=True)
        temporary = results.with_name(results.name + ".tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(
                    stream, RESULT_FIELDS, delimiter="\t", lineterminator="\n"
                )
                writer.writeheader()
                writer.writerows(rows)
            temporary.replace(results)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
    except (OSError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"qualified {len(rows)} DTD commands")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
