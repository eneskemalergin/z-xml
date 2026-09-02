#!/usr/bin/env python3
"""Qualify fresh and reusable DTD validation over fixed repeated schedules."""

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
from dataclasses import dataclass
from pathlib import Path

from qualification_io import file_identity, publish_tsv, read_limited

CORPUS_SCHEMA = "z-xml-validation-reuse-v1"
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
    "expected_result",
}
SEMANTIC_FIELDS = {
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
}
SEMANTIC_INTEGER_FIELDS = {
    "elements",
    "attributes",
    "defaulted_attributes",
    "text_bytes",
    "findings",
    "id_count",
    "idref_count",
}
SEMANTIC_OPTIONAL_INTEGER_FIELDS = {
    "first_finding_source_id",
    "first_finding_offset",
    "last_finding_source_id",
    "last_finding_offset",
}
SEMANTIC_STRING_FIELDS = {
    "event_checksum",
    "content",
    "validity",
    "findings_checksum",
}
SEMANTIC_OPTIONAL_STRING_FIELDS = {"first_finding", "last_finding"}
RESOLVER_FIELDS = {
    "resolver_calls",
    "resolved_sources",
    "closed_sources",
    "external_subset_sources",
    "source_bytes",
}
MEMORY_FIELDS = {
    "dtd_input_bytes",
    "caller_input_storage_bytes",
    "subset_declaration_capacity",
    "subset_validation_capacity",
    "subset_identifier_bytes",
    "subset_source_capacity",
    "subset_retained_bytes",
    "subset_allocator_operations",
    "subset_requested_bytes",
    "subset_peak_live_bytes",
    "subset_live_after_compile",
    "subset_live_after_documents",
    "subset_live_after_deinit",
    "reader_init_allocator_operations",
    "first_document_allocator_operations",
    "primary_warm_allocator_operations",
    "next_allocator_operations",
    "release_allocator_operations",
    "reader_allocator_allocs",
    "reader_allocator_resizes",
    "reader_allocator_remaps",
    "reader_requested_bytes",
    "reader_peak_live_bytes",
    "primary_grammar_capacity",
    "primary_identity_capacity",
    "primary_identity_bytes",
    "primary_document_capacity",
    "primary_retained_capacity",
    "final_grammar_capacity",
    "final_identity_capacity",
    "final_identity_bytes",
    "final_document_capacity",
    "final_retained_capacity",
    "reader_live_before_release",
    "reader_live_after_deinit",
    "resolver_allocator_operations",
    "resolver_requested_bytes",
    "resolver_peak_live_bytes",
    "resolver_live_after_documents",
    "retained_capacity_after_release",
    "reader_live_after_release",
}
TIMING_FIELDS = {
    "dtd_read_ns",
    "subset_compile_ns",
    "reader_init_ns",
    "first_document_ns",
    "primary_warm_ns",
    "next_documents_ns",
    "release_ns",
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
    "mode",
    "validity",
    "findings",
    "id_count",
    "idref_count",
    "subset_retained_bytes",
    "subset_allocator_operations",
    "subset_peak_live_bytes",
    "reader_init_allocator_operations",
    "first_document_allocator_operations",
    "primary_warm_allocator_operations",
    "next_allocator_operations",
    "reader_peak_live_bytes",
    "primary_grammar_capacity",
    "primary_identity_capacity",
    "primary_identity_bytes",
    "primary_document_capacity",
    "primary_retained_capacity",
    "final_grammar_capacity",
    "final_identity_capacity",
    "final_identity_bytes",
    "final_document_capacity",
    "final_retained_capacity",
    "resolver_allocator_operations",
    "resolver_peak_live_bytes",
    "reader_live_after_release",
    "reader_live_after_deinit",
    "subset_live_after_deinit",
    "dtd_read_ns",
    "subset_compile_ns",
    "reader_init_ns",
    "first_document_ns",
    "primary_warm_ns",
    "next_documents_ns",
    "release_ns",
]
REQUIRED_SCHEDULES = {
    "validation-reuse-small": (4096, None, 0),
    "validation-reuse-large": (8, None, 0),
    "validation-reuse-large-small": (1, "reuse-16k.xml", 4096),
    "validation-reuse-invalid": (2, None, 0),
}


@dataclass(frozen=True)
class Target:
    name: str
    program: Path
    mode: str
    features: frozenset[str]
    work_lane: str
    input_model: str


@dataclass(frozen=True)
class Workload:
    name: str
    source: Path
    resources: tuple[Path, ...]
    targets: tuple[str, ...]
    arguments: tuple[str, ...]
    iterations: int
    dtd_name: str
    dtd_path: Path
    next_name: str | None
    next_iterations: int
    expected: dict[str, object]


def decode_json(value: str) -> dict[str, object]:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, item in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON field {key}")
            result[key] = item
        return result

    def reject_constant(value: str) -> object:
        raise ValueError(f"invalid JSON number {value}")

    decoded = json.loads(
        value, object_pairs_hook=unique_object, parse_constant=reject_constant
    )
    if not isinstance(decoded, dict):
        raise TypeError("expected a JSON object")
    return decoded


def semantic_types_valid(result: dict[str, object]) -> bool:
    return (
        all(
            type(result[field]) is int and result[field] >= 0
            for field in SEMANTIC_INTEGER_FIELDS
        )
        and all(
            result[field] is None or (type(result[field]) is int and result[field] >= 0)
            for field in SEMANTIC_OPTIONAL_INTEGER_FIELDS
        )
        and all(
            isinstance(result[field], str) and bool(result[field])
            for field in SEMANTIC_STRING_FIELDS
        )
        and all(
            result[field] is None
            or (isinstance(result[field], str) and bool(result[field]))
            for field in SEMANTIC_OPTIONAL_STRING_FIELDS
        )
    )


def parse_protocol(arguments: tuple[str, ...]) -> tuple[str, int, str | None, int]:
    values: dict[str, str] = {}
    for argument in arguments:
        if "=" not in argument or not argument.startswith("--"):
            raise ValueError("validation reuse arguments must use --name=value")
        name, value = argument[2:].split("=", 1)
        if name not in {"dtd", "iterations", "next-file", "next-iterations"}:
            raise ValueError(f"unsupported validation reuse argument: {name}")
        if not value or name in values:
            raise ValueError(f"invalid validation reuse argument: {name}")
        values[name] = value
    required = {"dtd", "iterations"}
    if required.difference(values):
        raise ValueError("validation reuse arguments lack DTD or iteration count")
    if ("next-file" in values) != ("next-iterations" in values):
        raise ValueError("incomplete validation reuse transition")
    iterations = int(values["iterations"])
    next_iterations = int(values.get("next-iterations", "0"))
    if iterations <= 0 or next_iterations < 0:
        raise ValueError("invalid validation reuse iteration count")
    return values["dtd"], iterations, values.get("next-file"), next_iterations


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
        if len(fields) != 6:
            raise ValueError(f"{path}:{line_number}: expected six target fields")
        name, executable, processor, features, lane, input_model = fields
        if name in targets:
            raise ValueError(f"{path}:{line_number}: duplicate target")
        if name not in {"z-xml-validation-fresh", "z-xml-validation-reused"}:
            continue
        program = (root / executable).resolve()
        if not program.is_relative_to(root):
            raise ValueError(f"{path}:{line_number}: executable escapes bin directory")
        if processor != "validating" or lane != "validation-reuse":
            raise ValueError(f"{path}:{line_number}: invalid validation reuse target")
        feature_set = frozenset(features.split(","))
        required = {
            "dtd",
            "validation",
            "reader_reset",
            "validation_reuse_protocol",
            "memory_report",
            "timing_report",
        }
        if required.difference(feature_set) or input_model != "streaming-reader":
            raise ValueError(f"{path}:{line_number}: incomplete target contract")
        mode = "fresh" if name.endswith("fresh") else "reused"
        if mode == "fresh" and "external_dtd" not in feature_set:
            raise ValueError(f"{path}:{line_number}: fresh target lacks external DTD")
        if mode == "reused" and "reusable_external_subset" not in feature_set:
            raise ValueError(
                f"{path}:{line_number}: reused target lacks reusable subset"
            )
        targets[name] = Target(name, program, mode, feature_set, lane, input_model)
    if set(targets) != {"z-xml-validation-fresh", "z-xml-validation-reused"}:
        raise ValueError(f"{path}: both validation reuse targets are required")
    return targets


def read_workloads(path: Path) -> list[Workload]:
    lines = read_limited(path).decode("utf-8").splitlines()
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
        if name in names or name not in REQUIRED_SCHEDULES:
            raise ValueError(f"{path}:{line_number}: unexpected workload")
        names.add(name)
        source = (root / row["path"]).resolve()
        if not source.is_relative_to(root) or not source.is_file():
            raise ValueError(f"{path}:{line_number}: invalid input path")
        if source.stat().st_size != int(row["actual_bytes"]):
            raise ValueError(f"{path}:{line_number}: input size differs")
        if row["classification"] != "benchmark-valid":
            raise ValueError(f"{path}:{line_number}: invalid classification")
        resource_values = tuple(row["resource_paths"].split(","))
        if not resource_values or len(resource_values) != len(set(resource_values)):
            raise ValueError(f"{path}:{line_number}: invalid resources")
        resources: list[Path] = []
        for value in resource_values:
            resource = (root / value).resolve()
            if not resource.is_relative_to(root) or not resource.is_file():
                raise ValueError(f"{path}:{line_number}: invalid resource path")
            resources.append(resource)
        targets = tuple(row["targets"].split(","))
        if targets != ("z-xml-validation-fresh", "z-xml-validation-reused"):
            raise ValueError(f"{path}:{line_number}: invalid target pair")
        arguments = tuple(row["program_args"].split())
        dtd_name, iterations, next_name, next_iterations = parse_protocol(arguments)
        if (iterations, next_name, next_iterations) != REQUIRED_SCHEDULES[name]:
            raise ValueError(f"{path}:{line_number}: schedule differs")
        dtd_matches = [resource for resource in resources if resource.name == dtd_name]
        if len(dtd_matches) != 1 or dtd_matches[0].parent != source.parent:
            raise ValueError(f"{path}:{line_number}: DTD resource differs")
        if next_name is not None:
            next_matches = [
                resource for resource in resources if resource.name == next_name
            ]
            if len(next_matches) != 1 or next_matches[0].parent != source.parent:
                raise ValueError(f"{path}:{line_number}: next input differs")
        expected_resource_count = 2 if next_name is not None else 1
        if len(resources) != expected_resource_count:
            raise ValueError(f"{path}:{line_number}: unexpected resource")
        expected = decode_json(row["expected_result"])
        if set(expected) != {"primary", "next"}:
            raise ValueError(f"{path}:{line_number}: invalid expected result")
        primary = expected["primary"]
        next_result = expected["next"]
        if (
            not isinstance(primary, dict)
            or set(primary) != SEMANTIC_FIELDS
            or not semantic_types_valid(primary)
        ):
            raise ValueError(f"{path}:{line_number}: invalid primary result")
        if next_name is None:
            if next_result is not None:
                raise ValueError(f"{path}:{line_number}: unexpected next result")
        elif (
            not isinstance(next_result, dict)
            or set(next_result) != SEMANTIC_FIELDS
            or not semantic_types_valid(next_result)
        ):
            raise ValueError(f"{path}:{line_number}: invalid next result")
        workloads.append(
            Workload(
                name,
                source,
                tuple(resources),
                targets,
                arguments,
                iterations,
                dtd_name,
                dtd_matches[0],
                next_name,
                next_iterations,
                expected,
            )
        )
    if names != set(REQUIRED_SCHEDULES):
        raise ValueError(f"{path}: required schedule set differs")
    return workloads


def run_command(command: list[str], timeout: float) -> tuple[int, str, str, bool]:
    prlimit = shutil.which("prlimit")
    if prlimit is None:
        raise ValueError("prlimit from util-linux is required")
    limited = [
        prlimit,
        f"--cpu={max(1, math.ceil(timeout))}",
        f"--fsize={MAX_OUTPUT_BYTES + 1}",
        "--",
        *command,
    ]
    with (
        tempfile.TemporaryFile() as stdout_file,
        tempfile.TemporaryFile() as stderr_file,
    ):
        process = subprocess.Popen(
            limited,
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
    oversized = len(stdout) > MAX_OUTPUT_BYTES or len(stderr) > MAX_OUTPUT_BYTES
    return (
        process.returncode,
        stdout[:MAX_OUTPUT_BYTES].decode("utf-8", "replace"),
        stderr[:MAX_OUTPUT_BYTES].decode("utf-8", "replace"),
        timed_out or oversized,
    )


def prefixed_result(result: dict[str, object], prefix: str) -> dict[str, object]:
    return {f"{prefix}{field}": result[field] for field in SEMANTIC_FIELDS}


def expected_fields(workload: Workload) -> set[str]:
    fields = {"mode", "iterations", "input_bytes"} | SEMANTIC_FIELDS | RESOLVER_FIELDS
    if workload.next_name is not None:
        fields |= {"next_iterations", "next_input_bytes"}
        fields |= {f"next_{field}" for field in SEMANTIC_FIELDS}
    return fields


def check_semantics(
    target: Target, workload: Workload, result: dict[str, object]
) -> str | None:
    expected_keys = expected_fields(workload)
    if set(result) != expected_keys:
        return "semantic-fields-differ"
    if not semantic_types_valid(result):
        return "semantic-types-differ"
    if (
        result["mode"] != target.mode
        or type(result["iterations"]) is not int
        or result["iterations"] != workload.iterations
    ):
        return "protocol-mismatch"
    if (
        type(result["input_bytes"]) is not int
        or result["input_bytes"] != workload.source.stat().st_size
    ):
        return "input-size-mismatch"
    expected = workload.expected["primary"]
    assert isinstance(expected, dict)
    for field, value in expected.items():
        if result[field] != value:
            return f"primary-{field}-mismatch"
    if workload.next_name is not None:
        next_expected = workload.expected["next"]
        assert isinstance(next_expected, dict)
        next_observed = {field: result[f"next_{field}"] for field in SEMANTIC_FIELDS}
        if not semantic_types_valid(next_observed):
            return "next-semantic-types-differ"
        if (
            type(result["next_iterations"]) is not int
            or result["next_iterations"] != workload.next_iterations
        ):
            return "next-iteration-mismatch"
        next_path = workload.source.parent / workload.next_name
        if (
            type(result["next_input_bytes"]) is not int
            or result["next_input_bytes"] != next_path.stat().st_size
        ):
            return "next-size-mismatch"
        for field, value in prefixed_result(next_expected, "next_").items():
            if result[field] != value:
                return f"{field}-mismatch"
    document_count = workload.iterations + workload.next_iterations
    if target.mode == "fresh":
        expected_source_bytes = workload.dtd_path.stat().st_size * document_count
        expected_resolver = {
            "resolver_calls": document_count,
            "resolved_sources": document_count,
            "closed_sources": document_count,
            "external_subset_sources": document_count,
            "source_bytes": expected_source_bytes,
        }
    else:
        expected_resolver = {field: 0 for field in RESOLVER_FIELDS}
    for field, value in expected_resolver.items():
        if type(result[field]) is not int or result[field] != value:
            return f"{field}-mismatch"
    return None


def check_memory(
    target: Target, workload: Workload, result: dict[str, object]
) -> str | None:
    if any(
        type(result[field]) is not int or result[field] < 0 for field in MEMORY_FIELDS
    ):
        return "invalid-memory"
    if result["dtd_input_bytes"] != workload.dtd_path.stat().st_size:
        return "dtd-input-size-mismatch"
    expected_input_storage = 64 * 1024 * (2 if workload.next_name else 1)
    if result["caller_input_storage_bytes"] != expected_input_storage:
        return "caller-input-storage-mismatch"
    subset_parts = sum(
        int(result[field])
        for field in (
            "subset_declaration_capacity",
            "subset_validation_capacity",
            "subset_identifier_bytes",
            "subset_source_capacity",
        )
    )
    if result["subset_retained_bytes"] != subset_parts:
        return "subset-accounting-mismatch"
    subset_numeric = [
        int(result[field]) for field in MEMORY_FIELDS if field.startswith("subset_")
    ]
    if target.mode == "fresh":
        if any(subset_numeric):
            return "fresh-subset-storage-present"
    else:
        if (
            result["subset_declaration_capacity"] <= 0
            or result["subset_validation_capacity"] <= 0
            or result["subset_allocator_operations"] <= 0
            or result["subset_peak_live_bytes"] < result["subset_retained_bytes"]
            or result["subset_live_after_compile"] != result["subset_retained_bytes"]
            or result["subset_live_after_documents"] != result["subset_retained_bytes"]
            or result["subset_live_after_deinit"] != 0
        ):
            return "reused-subset-lifecycle-mismatch"
    for phase in ("primary", "final"):
        if result[f"{phase}_retained_capacity"] != (
            result[f"{phase}_grammar_capacity"] + result[f"{phase}_document_capacity"]
        ):
            return f"{phase}-reader-accounting-mismatch"
    if result["reader_live_before_release"] != result["final_retained_capacity"]:
        return "reader-live-accounting-mismatch"
    if (
        result["retained_capacity_after_release"] != 0
        or result["reader_live_after_release"] != 0
        or result["reader_live_after_deinit"] != 0
        or result["resolver_live_after_documents"] != 0
    ):
        return "cleanup-mismatch"
    if result["first_document_allocator_operations"] <= 0:
        return "first-document-allocation-missing"
    if target.mode == "fresh":
        if (
            result["resolver_allocator_operations"] <= 0
            or result["resolver_peak_live_bytes"] <= 0
        ):
            return "fresh-resolver-memory-missing"
    elif (
        result["resolver_allocator_operations"] != 0
        or result["resolver_peak_live_bytes"] != 0
    ):
        return "reused-resolver-memory-present"
    if workload.next_name is None:
        for field in (
            "grammar_capacity",
            "identity_capacity",
            "identity_bytes",
            "document_capacity",
            "retained_capacity",
        ):
            if result[f"primary_{field}"] != result[f"final_{field}"]:
                return f"nontransition-{field}-mismatch"
    elif (
        result["primary_identity_bytes"] <= result["final_identity_bytes"]
        or result["final_identity_capacity"] < result["primary_identity_capacity"]
        or result["final_retained_capacity"] < result["primary_retained_capacity"]
    ):
        return "large-small-retention-mismatch"
    return None


def check_timing(
    target: Target, workload: Workload, result: dict[str, object]
) -> str | None:
    if any(
        type(result[field]) is not int or result[field] < 0 for field in TIMING_FIELDS
    ):
        return "invalid-timing"
    if target.mode == "fresh":
        if result["dtd_read_ns"] != 0 or result["subset_compile_ns"] != 0:
            return "fresh-setup-timing-present"
    elif result["dtd_read_ns"] <= 0 or result["subset_compile_ns"] <= 0:
        return "reused-setup-timing-missing"
    if result["reader_init_ns"] <= 0 or result["first_document_ns"] <= 0:
        return "reader-timing-missing"
    if (result["primary_warm_ns"] > 0) != (workload.iterations > 1):
        return "primary-warm-timing-mismatch"
    if (result["next_documents_ns"] > 0) != (workload.next_name is not None):
        return "next-timing-mismatch"
    if result["release_ns"] <= 0:
        return "release-timing-missing"
    return None


def command_result(
    target: Target,
    workload: Workload,
    command: list[str],
    timeout: float,
    detailed: bool,
) -> tuple[dict[str, object] | None, str | None]:
    status, stdout, stderr, bounded_failure = run_command(command, timeout)
    if bounded_failure:
        return None, "timeout-or-output-limit"
    if status != 0:
        return None, f"status-{status}:{stderr.strip() or 'no-stderr'}"
    try:
        result = decode_json(stdout)
    except (json.JSONDecodeError, TypeError, ValueError) as error:
        return None, f"invalid-json:{error}"
    base_fields = expected_fields(workload)
    expected = base_fields | (MEMORY_FIELDS | TIMING_FIELDS if detailed else set())
    if set(result) != expected:
        return None, "result-fields-differ"
    semantic = {field: result[field] for field in base_fields}
    error = check_semantics(target, workload, semantic)
    if error is not None:
        return None, error
    if detailed:
        error = check_memory(target, workload, result) or check_timing(
            target, workload, result
        )
        if error is not None:
            return None, error
    return result, None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=600.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.timeout <= 0:
        raise ValueError("timeout must be positive")
    manifest = args.manifest.resolve()
    targets_path = args.targets.resolve()
    results = args.results.resolve()
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
        args.results.is_symlink()
        or results.is_relative_to(manifest.parent)
        or results in input_paths
    ):
        raise ValueError("result path overlaps an input or uses a symlink")
    results.unlink(missing_ok=True)
    tracked = {
        manifest: file_identity(manifest),
        targets_path: file_identity(targets_path),
    }
    rows: list[dict[str, object]] = []
    semantic_pairs: dict[str, dict[str, dict[str, object]]] = {}
    for workload in workloads:
        identities = {workload.source: file_identity(workload.source)}
        identities.update({path: file_identity(path) for path in workload.resources})
        for target_name in workload.targets:
            target = targets[target_name]
            if not target.program.is_file() or not os.access(target.program, os.X_OK):
                raise ValueError(f"missing executable: {target.program}")
            command_identities = {
                **identities,
                target.program: file_identity(target.program),
            }
            command = [str(target.program), *workload.arguments, str(workload.source)]
            semantic, semantic_error = command_result(
                target, workload, command, args.timeout, False
            )
            detailed_command = [
                str(target.program),
                *workload.arguments,
                "--report-memory",
                "--report-timing",
                "--release-memory",
                str(workload.source),
            ]
            detailed, detailed_error = command_result(
                target, workload, detailed_command, args.timeout, True
            )
            verdict = semantic_error or detailed_error or "pass"
            if semantic is not None and detailed is not None:
                base = expected_fields(workload)
                if any(semantic[field] != detailed[field] for field in base):
                    verdict = "instrumentation-changed-semantics"
                semantic_pairs.setdefault(workload.name, {})[target.mode] = semantic
            if any(
                file_identity(path) != identity
                for path, identity in command_identities.items()
            ):
                verdict = "input-changed"
            row: dict[str, object] = {field: "" for field in RESULT_FIELDS}
            row.update(
                {
                    "target": target.name,
                    "workload": workload.name,
                    "classification": "benchmark-valid",
                    "verdict": verdict,
                    "work_lane": target.work_lane,
                    "input_model": target.input_model,
                    "program_args": " ".join(workload.arguments),
                    "status": 0,
                    "mode": target.mode,
                }
            )
            if semantic is not None:
                for field in ("validity", "findings", "id_count", "idref_count"):
                    row[field] = semantic[field]
            if detailed is not None:
                for field in RESULT_FIELDS:
                    if field in detailed:
                        row[field] = detailed[field]
            rows.append(row)
    for workload in workloads:
        pair = semantic_pairs.get(workload.name, {})
        if set(pair) != {"fresh", "reused"}:
            continue
        ignored = RESOLVER_FIELDS | {"mode"}
        parity_fields = expected_fields(workload) - ignored
        if any(
            pair["fresh"][field] != pair["reused"][field] for field in parity_fields
        ):
            for row in rows:
                if row["workload"] == workload.name:
                    row["verdict"] = "fresh-reused-semantic-mismatch"
    if any(file_identity(path) != identity for path, identity in tracked.items()):
        raise ValueError("control file changed during qualification")
    failed = [row for row in rows if row["verdict"] != "pass"]
    if failed:
        for row in failed:
            print(
                f"{row['target']}/{row['workload']}: {row['verdict']}", file=sys.stderr
            )
        return 1
    publish_tsv(results, RESULT_FIELDS, rows)
    print(f"qualified {len(rows)} validation reuse commands at {results}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
