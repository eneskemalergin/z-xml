#!/usr/bin/env python3
"""Qualify fresh DTD-validation commands against exact generated results."""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

CORPUS_SCHEMA = "z-xml-validation-generated-v1"
TARGET_SCHEMA = "z-xml-targets-v1"
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
MAX_CONTROL_BYTES = 16 * 1024 * 1024
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
    "event_checksum",
    "content",
    "validity",
    "findings",
    "findings_checksum",
    "first_finding",
    "first_finding_source_id",
    "first_finding_offset",
    "last_finding",
    "last_finding_source_id",
    "last_finding_offset",
    "id_count",
    "idref_count",
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
    "content_model_capacity",
    "grammar_capacity",
    "identity_capacity",
    "identity_bytes",
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
    "validity",
    "findings",
    "first_finding_source_id",
    "first_finding_offset",
    "last_finding_source_id",
    "last_finding_offset",
    "id_count",
    "idref_count",
    "dtd_capacity",
    "content_model_capacity",
    "grammar_capacity",
    "identity_capacity",
    "identity_bytes",
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
    features: frozenset[str]
    work_lane: str
    input_model: str


@dataclass(frozen=True)
class Workload:
    name: str
    source: Path
    resources: tuple[Path, ...]
    classification: str
    target: str
    arguments: tuple[str, ...]
    expected_status: int
    expected_result: dict[str, object]


def read_limited(path: Path, limit: int = MAX_CONTROL_BYTES) -> bytes:
    if not path.is_file():
        raise ValueError(f"{path}: expected a regular file")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{path}: exceeds the {limit}-byte control limit")
    return data


def decode_json(value: str) -> dict[str, object]:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, item in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON field {key}")
            result[key] = item
        return result

    decoded = json.loads(value, object_pairs_hook=unique_object)
    if not isinstance(decoded, dict):
        raise TypeError("expected a JSON object")
    return decoded


def file_identity(path: Path) -> tuple[int, int, int, int]:
    status = path.stat()
    return status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns


def read_targets(path: Path, bin_dir: Path) -> dict[str, Target]:
    lines = read_limited(path).decode("utf-8").splitlines()
    if len(lines) < 3 or lines[0].removeprefix("#").strip() != TARGET_SCHEMA:
        raise ValueError(f"{path}: unsupported target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{path}: invalid target header")
    root = bin_dir.resolve()
    targets: dict[str, Target] = {}
    for line_number, line in enumerate(lines[2:], 3):
        fields = line.split("\t")
        if len(fields) != 6 or any(not field for field in fields):
            raise ValueError(f"{path}:{line_number}: invalid target fields")
        name, executable, processor, feature_text, work_lane, input_model = fields
        features = frozenset(feature_text.split(","))
        if work_lane != "validation":
            continue
        if (
            processor != "validating"
            or input_model != "streaming-reader"
            or not {"xml1_0_5e", "namespaces", "dtd", "validation"}.issubset(features)
        ):
            raise ValueError(f"{path}:{line_number}: target is not fresh validation")
        if name in targets:
            raise ValueError(f"{path}:{line_number}: duplicate target {name}")
        program = (root / executable).resolve()
        if not program.is_relative_to(root):
            raise ValueError(f"{path}:{line_number}: executable escapes binary root")
        targets[name] = Target(name, program, features, work_lane, input_model)
    if not targets:
        raise ValueError(f"{path}: empty target manifest")
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
        arguments = (
            () if row["program_args"] == "-" else tuple(row["program_args"].split())
        )
        if "--report-memory" in arguments:
            raise ValueError(
                f"{path}:{line_number}: memory flag belongs to the checker"
            )
        expected_status = int(row["expected_status"])
        if expected_status not in {0, 1, 2, 3}:
            raise ValueError(f"{path}:{line_number}: invalid expected status")
        if row["classification"] not in {"benchmark-valid", "not-well-formed"}:
            raise ValueError(f"{path}:{line_number}: invalid classification")
        expected_result = decode_json(row["expected_result"])
        if set(expected_result) != SEMANTIC_FIELDS:
            raise ValueError(f"{path}:{line_number}: invalid expected fields")
        workloads.append(
            Workload(
                name,
                source,
                tuple(resources),
                row["classification"],
                row["targets"],
                arguments,
                expected_status,
                expected_result,
            )
        )
    if not workloads:
        raise ValueError(f"{path}: empty corpus")
    return workloads


def run_command(command: list[str], timeout: float) -> tuple[int, str, str, bool, bool]:
    prlimit = shutil.which("prlimit")
    if prlimit is None:
        raise ValueError("prlimit from util-linux is required")
    limited_command = [prlimit, f"--fsize={MAX_OUTPUT_BYTES + 1}", "--", *command]
    with (
        tempfile.TemporaryFile() as stdout_file,
        tempfile.TemporaryFile() as stderr_file,
    ):
        process = subprocess.Popen(
            limited_command,
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
    overflow = (
        len(stdout) > MAX_OUTPUT_BYTES
        or len(stderr) > MAX_OUTPUT_BYTES
        or process.returncode in {-signal.SIGXFSZ, 128 + signal.SIGXFSZ}
    )
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
        observed = decode_json(stdout)
    except (TypeError, ValueError, json.JSONDecodeError):
        return None, "invalid-json"
    expected_fields = SEMANTIC_FIELDS | (MEMORY_FIELDS if memory else set())
    if set(observed) != expected_fields:
        return None, "unexpected-fields"
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
        observed["live_bytes_after_deinit"] != 0
        or observed["caller_external_live_after_deinit"] != 0
        or observed["resolved_sources"] != observed["closed_sources"]
        or observed["caller_root_storage_bytes"] != 64 * 1024
        or observed["grammar_capacity"]
        != observed["dtd_capacity"] + observed["content_model_capacity"]
        or observed["retained_capacity"] < observed["grammar_capacity"]
        or observed["document_capacity"]
        != observed["retained_capacity"] - observed["grammar_capacity"]
        or observed["identity_capacity"] < observed["identity_bytes"]
        or observed["requested_bytes"] < observed["peak_live_bytes"]
        or observed["peak_live_bytes"] < observed["live_bytes_before_deinit"]
        or observed["live_bytes_before_deinit"] != observed["retained_capacity"]
    ):
        return None, "memory-invariant"
    return observed, None


def write_results(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="", dir=path.parent, delete=False
        ) as stream:
            temporary = Path(stream.name)
            writer = csv.DictWriter(
                stream, RESULT_FIELDS, delimiter="\t", lineterminator="\n"
            )
            writer.writeheader()
            writer.writerows(rows)
        temporary.replace(path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=120.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.timeout <= 0:
        print("timeout must be positive", file=sys.stderr)
        return 64
    results_path = args.results.resolve()
    try:
        manifest = args.manifest.resolve()
        target_path = args.targets.resolve()
        bin_dir = args.bin_dir.resolve()
        targets = read_targets(target_path, bin_dir)
        selected = set(args.target) if args.target else set(targets)
        unknown = selected.difference(targets)
        if unknown:
            raise ValueError("unknown targets: " + ",".join(sorted(unknown)))
        workloads = read_workloads(manifest)
        unknown_workload_targets = {
            workload.target for workload in workloads if workload.target not in targets
        }
        if unknown_workload_targets:
            raise ValueError(
                "manifest uses unknown targets: "
                + ",".join(sorted(unknown_workload_targets))
            )
        selected_workloads = [
            workload for workload in workloads if workload.target in selected
        ]
        selected_programs = {targets[name].program for name in selected}
        input_paths = {
            manifest,
            target_path,
            *selected_programs,
            *(workload.source for workload in selected_workloads),
            *(
                resource
                for workload in selected_workloads
                for resource in workload.resources
            ),
        }
        if (
            args.results.is_symlink()
            or results_path.is_relative_to(manifest.parent)
            or results_path in input_paths
        ):
            raise ValueError("result path overlaps an input or uses a symlink")
        results_path.unlink(missing_ok=True)
        rows: list[dict[str, object]] = []
        manifest_identity = file_identity(manifest)
        target_identity = file_identity(target_path)
        for workload in selected_workloads:
            target = targets.get(workload.target)
            if target is None:
                raise ValueError(f"{workload.name}: target is not declared")
            if not target.program.is_file() or not os.access(target.program, os.X_OK):
                raise ValueError(f"missing executable: {target.program}")
            if workload.resources and not {
                "external_dtd",
                "external_general_entities",
                "external_parameter_entities",
            }.issubset(target.features):
                raise ValueError(
                    f"{workload.name}: target lacks required external features"
                )
            identities = {
                workload.source: file_identity(workload.source),
                target.program: file_identity(target.program),
            }
            identities.update(
                {resource: file_identity(resource) for resource in workload.resources}
            )
            command = [
                str(target.program),
                *workload.arguments,
                str(workload.source),
            ]
            semantic, error = check_result(
                workload, run_command(command, args.timeout), False
            )
            memory_command = [
                str(target.program),
                *workload.arguments,
                "--report-memory",
                str(workload.source),
            ]
            memory, memory_error = check_result(
                workload, run_command(memory_command, args.timeout), True
            )
            verdict = error or memory_error or "pass"
            if any(
                file_identity(path) != identity for path, identity in identities.items()
            ):
                verdict = "input-changed"
            row: dict[str, object] = {
                "target": target.name,
                "workload": workload.name,
                "classification": workload.classification,
                "verdict": verdict,
                "work_lane": target.work_lane,
                "input_model": target.input_model,
                "program_args": " ".join(workload.arguments) or "-",
                "status": workload.expected_status,
                "validity": "",
                "findings": "",
                "first_finding_source_id": "",
                "first_finding_offset": "",
                "last_finding_source_id": "",
                "last_finding_offset": "",
                "id_count": "",
                "idref_count": "",
                "dtd_capacity": "",
                "content_model_capacity": "",
                "grammar_capacity": "",
                "identity_capacity": "",
                "identity_bytes": "",
                "document_capacity": "",
                "retained_capacity": "",
                "peak_live_bytes": "",
                "allocator_operations": "",
                "caller_root_storage_bytes": "",
                "caller_external_peak_bytes": "",
                "live_bytes_after_deinit": "",
                "caller_external_live_after_deinit": "",
            }
            if semantic is not None:
                for field in (
                    "validity",
                    "findings",
                    "first_finding_source_id",
                    "first_finding_offset",
                    "last_finding_source_id",
                    "last_finding_offset",
                    "id_count",
                    "idref_count",
                ):
                    row[field] = semantic[field] if semantic[field] is not None else ""
            if memory is not None:
                for field in MEMORY_FIELDS:
                    if field in row:
                        row[field] = memory[field]
            rows.append(row)
        if not rows:
            raise ValueError("no selected validation commands")
        if any(row["verdict"] != "pass" for row in rows):
            for row in rows:
                if row["verdict"] != "pass":
                    print(
                        f"{row['target']}/{row['workload']}: {row['verdict']}",
                        file=sys.stderr,
                    )
            return 1
        if file_identity(manifest) != manifest_identity:
            raise ValueError("manifest changed during qualification")
        if file_identity(target_path) != target_identity:
            raise ValueError("target declarations changed during qualification")
        write_results(results_path, rows)
        print(f"validation qualification passed: {len(rows)} commands")
        return 0
    except (OSError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
