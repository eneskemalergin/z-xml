#!/usr/bin/env python3
"""Qualify one declared persistent adapter against a generated corpus."""

from __future__ import annotations

import argparse
import csv
import math
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from itertools import pairwise
from pathlib import Path

from qualification_io import decode_json

MAX_WORKLOAD_BYTES = 1024 * 1024 * 1024
CORPUS_SCHEMA = "z-xml-generated-v3"
NAMESPACE_SCHEMA = "z-xml-namespace-benchmark-v1"
TARGET_SCHEMA = "z-xml-persistent-targets-v1"
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
GENERAL_COLUMNS = [
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
NAMESPACE_COLUMNS = [
    "id",
    "path",
    "shape",
    "actual_bytes",
    "classification",
    "expected_summary",
]
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
NAMESPACE_FIELDS = {
    "namespace_declarations",
    "namespace_uri_bytes",
    "local_name_bytes",
    "prefix_bytes",
}
MEMORY_FIELDS = {
    "input_bytes",
    "parser_storage",
    "first_allocator_operations",
    "warm_allocator_operations",
    "allocator_allocs",
    "allocator_resizes",
    "allocator_remaps",
    "requested_bytes",
    "peak_live_bytes",
    "retained_capacity",
    "live_bytes_before_deinit",
    "live_bytes_after_deinit",
    "caller_input_storage_bytes",
}
TRANSITION_FIELDS = {
    "next_iterations",
    "next_input_bytes",
    "next_elements",
    "next_attributes",
    "next_text_bytes",
    "next_name_bytes",
    "next_value_bytes",
    "next_fragments",
    "next_accumulator",
}
TRANSITION_NAMESPACE_FIELDS = {
    "next_namespace_declarations",
    "next_namespace_uri_bytes",
    "next_local_name_bytes",
    "next_prefix_bytes",
}
TRANSITION_MEMORY_FIELDS = {
    "primary_warm_allocator_operations",
    "next_allocator_operations",
}
RELEASE_MEMORY_FIELDS = {
    "release_allocator_operations",
    "live_bytes_before_release",
    "retained_capacity_after_release",
    "live_bytes_after_release",
}
TIMING_FIELDS = {
    "source_setup_ns",
    "reader_init_ns",
    "first_document_ns",
    "primary_warm_ns",
    "next_documents_ns",
    "release_ns",
}
FLAT_MEMORY_FIELDS = {
    "first_allocator_operations",
    "allocator_allocs",
    "allocator_resizes",
    "allocator_remaps",
    "requested_bytes",
    "peak_live_bytes",
    "retained_capacity",
    "live_bytes_before_deinit",
}
COMMON_SUMMARY_FIELDS = {"elements", "attributes", "text_bytes", "checksum"}
NAMESPACE_SUMMARY_FIELDS = COMMON_SUMMARY_FIELDS | {
    "name_bytes",
    "value_bytes",
    *NAMESPACE_FIELDS,
}
RESULT_FIELDS = [
    "elements",
    "attributes",
    "text_bytes",
    "name_bytes",
    "value_bytes",
    "fragments",
    "namespace_declarations",
    "namespace_uri_bytes",
    "local_name_bytes",
    "prefix_bytes",
    "accumulator",
]
CONSUMER_PARITY_FIELDS = (
    "elements",
    "attributes",
    "text_bytes",
    "name_bytes",
    "value_bytes",
    "fragments",
)


@dataclass(frozen=True)
class Target:
    name: str
    executable: str
    processor_class: str
    features: frozenset[str]
    work_lane: str
    input_model: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--program", type=Path, required=True)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--program-arg", action="append", default=[])
    parser.add_argument("--next-workload")
    parser.add_argument("--next-iterations", type=int)
    parser.add_argument("--namespace", action="store_true")
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--workload", action="append", default=[])
    parser.add_argument("--shape", action="append", default=[])
    parser.add_argument("--input", action="append", choices=("resident", "stream"))
    parser.add_argument("--consumer", action="append", choices=("minimal", "full"))
    parser.add_argument("--chunk-bytes", action="append", type=int)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--max-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--address-space-mib", type=int, default=2048)
    parser.add_argument("--cpu-seconds", type=int, default=30)
    parser.add_argument("--open-files", type=int, default=64)
    parser.add_argument("--max-output-bytes", type=int, default=64 * 1024)
    parser.add_argument("--report-memory", action="store_true")
    parser.add_argument("--report-timing", action="store_true")
    parser.add_argument("--release-memory", action="store_true")
    parser.add_argument("--check-scale", action="store_true")
    return parser.parse_args()


def result_path(args: argparse.Namespace, program: Path) -> Path:
    resolved = args.results.resolve()
    manifest = args.manifest.resolve()
    targets = args.targets.resolve()
    corpus_root = args.manifest.parent.resolve()
    if (
        args.results.is_symlink()
        or resolved in {manifest, targets, program}
        or resolved.is_relative_to(corpus_root)
    ):
        raise ValueError("result path overlaps a checker input")
    return resolved


def read_target(
    path: Path,
    selected: str,
    program: Path,
    namespace: bool,
    consumers: list[str],
    report_memory: bool,
) -> Target:
    with path.open(encoding="utf-8") as stream:
        lines = list(stream)
    if len(lines) < 3 or lines[0].removeprefix("#").strip() != TARGET_SCHEMA:
        raise ValueError(f"{path}: unsupported persistent target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{path}: invalid persistent target header")
    found: Target | None = None
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
            processor_class not in {"wf", "partial"}
            or work_lane not in {"event-persistent", "event-persistent-namespace"}
            or input_model != "resident-or-stream"
        ):
            raise ValueError(f"{path}:{line_number}: invalid target declaration")
        if name == selected:
            found = Target(
                name=name,
                executable=executable,
                processor_class=processor_class,
                features=frozenset(features),
                work_lane=work_lane,
                input_model=input_model,
            )
    if found is None:
        raise ValueError(f"{path}: unknown target {selected}")
    expected_lane = "event-persistent-namespace" if namespace else "event-persistent"
    if (
        found.processor_class not in {"wf", "partial"}
        or found.work_lane != expected_lane
        or found.input_model != "resident-or-stream"
    ):
        raise ValueError(f"{found.name}: target does not declare the requested lane")
    required_features = {
        "persistent_protocol",
        "event_counts",
        "fragment_counts",
        *(f"{consumer}_consumer" for consumer in consumers),
    }
    if namespace:
        required_features.add("namespaces")
    if report_memory:
        required_features.add("memory_report")
    missing = sorted(required_features.difference(found.features))
    if missing:
        raise ValueError(f"{found.name}: missing target features: {','.join(missing)}")
    if program.name != found.executable:
        raise ValueError(f"{found.name}: program does not match target declaration")
    return found


def read_workloads(
    manifest: Path,
    max_bytes: int,
    selected_ids: set[str],
    selected_shapes: set[str],
    namespace: bool,
) -> list[dict[str, object]]:
    with manifest.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    comments = [line[1:].strip() for line in lines if line.startswith("#")]
    expected_comments = (
        [NAMESPACE_SCHEMA]
        if namespace
        else [CORPUS_SCHEMA, f"size ceiling: {MAX_WORKLOAD_BYTES} bytes"]
    )
    if comments != expected_comments:
        raise ValueError(f"{manifest}: invalid generated-corpus identity")
    reader = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    expected_columns = NAMESPACE_COLUMNS if namespace else GENERAL_COLUMNS
    if reader.fieldnames != expected_columns:
        raise ValueError(f"{manifest}: invalid generated-corpus columns")
    rows = list(reader)
    if not rows:
        raise ValueError(f"{manifest}: generated manifest is empty")

    root = manifest.parent.resolve()
    selected_rows: list[dict[str, object]] = []
    known_ids: set[str] = set()
    known_shapes: set[str] = set()
    seen_paths: set[Path] = set()
    for line_number, row in enumerate(rows, len(comments) + 2):
        if None in row or any(value is None or value == "" for value in row.values()):
            raise ValueError(f"{manifest}:{line_number}: invalid workload row")
        item_id = row["id"]
        if item_id in known_ids:
            raise ValueError(
                f"{manifest}:{line_number}: duplicate workload ID {item_id}"
            )
        known_ids.add(item_id)
        known_shapes.add(row["shape"])
        path = (root / row["path"]).resolve()
        try:
            path.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{item_id}: path escapes generated corpus") from error
        if path in seen_paths:
            raise ValueError(f"{item_id}: duplicate workload path")
        seen_paths.add(path)
        try:
            size = int(row["actual_bytes"])
        except ValueError as error:
            raise ValueError(f"{item_id}: invalid workload size") from error
        if size <= 0 or size > MAX_WORKLOAD_BYTES:
            raise ValueError(f"{item_id}: invalid workload size")
        if not namespace:
            try:
                target_bytes = int(row["target_bytes"])
            except ValueError as error:
                raise ValueError(f"{item_id}: invalid target size") from error
            if target_bytes < 0 or (target_bytes and target_bytes != size):
                raise ValueError(f"{item_id}: byte size differs from target")
            features = row["feature_checks"].split(",")
            if any(not feature for feature in features) or len(features) != len(
                set(features)
            ):
                raise ValueError(f"{item_id}: invalid feature checks")
        try:
            observed_size = path.stat().st_size
        except OSError as error:
            raise ValueError(f"{item_id}: {error}") from error
        if not path.is_file() or observed_size != size:
            raise ValueError(f"{item_id}: byte size differs from manifest")

        expected: dict[str, object] | None
        if row["classification"] == "benchmark-valid":
            try:
                decoded = decode_json(row["expected_summary"])
            except ValueError as error:
                raise ValueError(f"{item_id}: invalid expected summary") from error
            expected_fields = (
                NAMESPACE_SUMMARY_FIELDS if namespace else COMMON_SUMMARY_FIELDS
            )
            if not isinstance(decoded, dict) or set(decoded) != expected_fields:
                raise ValueError(f"{item_id}: invalid expected summary")
            integer_fields = expected_fields - {"checksum"}
            if any(
                type(decoded[field]) is not int or decoded[field] < 0
                for field in integer_fields
            ):
                raise ValueError(f"{item_id}: invalid expected summary values")
            checksum = decoded["checksum"]
            if not isinstance(checksum, str) or len(checksum) != 16:
                raise ValueError(f"{item_id}: invalid expected summary checksum")
            try:
                checksum_value = int(checksum, 16)
            except ValueError as error:
                raise ValueError(
                    f"{item_id}: invalid expected summary checksum"
                ) from error
            if checksum_value > 0xFFFFFFFFFFFFFFFF:
                raise ValueError(f"{item_id}: invalid expected summary checksum")
            if not namespace:
                try:
                    declared = (
                        int(row["elements"]),
                        int(row["attributes"]),
                        int(row["normalized_text_bytes"]),
                    )
                except ValueError as error:
                    raise ValueError(f"{item_id}: invalid summary columns") from error
                if declared != (
                    decoded["elements"],
                    decoded["attributes"],
                    decoded["text_bytes"],
                ):
                    raise ValueError(f"{item_id}: summary columns disagree")
                if any(
                    row[field] != "-"
                    for field in (
                        "rejection_fraction",
                        "fatal_offset",
                        "fatal_fraction",
                    )
                ):
                    raise ValueError(
                        f"{item_id}: valid workload has rejection metadata"
                    )
            expected = decoded
        elif row["classification"] == "not-well-formed":
            if namespace:
                raise ValueError(
                    f"{item_id}: namespace manifest has no rejection oracle"
                )
            if row["expected_summary"] != "-":
                raise ValueError(f"{item_id}: invalid rejection summary")
            if (
                row["shape"] != "rejection"
                or any(
                    row[field] == "-"
                    for field in (
                        "rejection_fraction",
                        "fatal_offset",
                        "fatal_fraction",
                    )
                )
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
            expected = None
        else:
            raise ValueError(f"{item_id}: unsupported classification")

        if (
            (not selected_ids or item_id in selected_ids)
            and (not selected_shapes or row["shape"] in selected_shapes)
            and size <= max_bytes
        ):
            selected_rows.append({**row, "resolved_path": path, "expected": expected})
    unknown_ids = selected_ids.difference(known_ids)
    if unknown_ids:
        raise ValueError(
            f"{manifest}: unknown workloads: {','.join(sorted(unknown_ids))}"
        )
    unknown_shapes = selected_shapes.difference(known_shapes)
    if unknown_shapes:
        raise ValueError(
            f"{manifest}: unknown shapes: {','.join(sorted(unknown_shapes))}"
        )
    if not selected_rows:
        raise ValueError(f"{manifest}: no workload at or below the byte limit")
    return selected_rows


def observe(
    program: Path,
    engine: str,
    program_args: list[str],
    workload: dict[str, object],
    next_workload: dict[str, object] | None,
    next_iterations: int,
    input_model: str,
    consumer: str,
    chunk_bytes: int,
    args: argparse.Namespace,
) -> tuple[str, str, dict[str, object] | None]:
    command = [
        "prlimit",
        f"--as={args.address_space_mib * 1024 * 1024}",
        f"--cpu={args.cpu_seconds}",
        f"--nofile={args.open_files}",
        f"--fsize={args.max_output_bytes}",
        "--",
        str(program),
        *program_args,
        f"--input={input_model}",
        f"--consumer={consumer}",
        f"--iterations={args.iterations}",
        f"--chunk-bytes={chunk_bytes}",
    ]
    if args.report_memory:
        command.append("--report-memory")
    if args.report_timing:
        command.append("--report-timing")
    if args.release_memory:
        command.append("--release-memory")
    if next_workload is not None:
        command.extend(
            [
                f"--next-file={next_workload['resolved_path']}",
                f"--next-iterations={next_iterations}",
            ]
        )
    command.append(str(workload["resolved_path"]))
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
        return "error", "timeout", None
    except OSError as error:
        return "error", str(error), None
    if len(output) > args.max_output_bytes or len(diagnostic) > args.max_output_bytes:
        return "error", "output-limit", None
    if completed.returncode in {-signal.SIGXFSZ, 128 + signal.SIGXFSZ}:
        return "error", "output-limit", None
    if workload["classification"] == "not-well-formed":
        if completed.returncode == 2:
            return "pass", "-", None
        return "fail", f"expected-status-2-observed-{completed.returncode}", None
    if completed.returncode != 0:
        return "error", f"status-{completed.returncode}", None

    try:
        observed = decode_json(output)
    except (UnicodeDecodeError, ValueError):
        return "error", "invalid-json", None
    expected_output_fields = (
        EXPECTED_FIELDS
        | (NAMESPACE_FIELDS if args.namespace else set())
        | (MEMORY_FIELDS if args.report_memory else set())
        | (TRANSITION_FIELDS if next_workload is not None else set())
        | (
            TRANSITION_NAMESPACE_FIELDS
            if next_workload is not None and args.namespace
            else set()
        )
        | (
            TRANSITION_MEMORY_FIELDS
            if next_workload is not None and args.report_memory
            else set()
        )
        | (
            RELEASE_MEMORY_FIELDS
            if args.release_memory and args.report_memory
            else set()
        )
        | (TIMING_FIELDS if args.report_timing else set())
    )
    if not isinstance(observed, dict) or set(observed) != expected_output_fields:
        return "error", "unexpected-fields", None
    metadata = {
        "engine": engine,
        "input": input_model,
        "consumer": consumer,
        "iterations": args.iterations,
        "chunk_bytes": chunk_bytes,
    }
    if any(
        type(observed[key]) is not type(value) or observed[key] != value
        for key, value in metadata.items()
    ):
        return "fail", "metadata-mismatch", observed
    numeric_fields = {
        "elements",
        "attributes",
        "text_bytes",
        "name_bytes",
        "value_bytes",
        "fragments",
    } | (NAMESPACE_FIELDS if args.namespace else set())
    if any(
        type(observed[field]) is not int or observed[field] < 0
        for field in numeric_fields
    ):
        return "error", "invalid-counter", observed

    expected = workload["expected"]
    assert isinstance(expected, dict)
    counters = ["elements", "attributes", "text_bytes"]
    if args.namespace:
        counters.extend(["name_bytes", "value_bytes", *sorted(NAMESPACE_FIELDS)])
    for field in counters:
        if observed[field] != expected[field]:
            return "fail", f"{field}-mismatch", observed
    accumulator = expected["checksum"] if consumer == "full" else None
    if observed["accumulator"] != accumulator:
        return "fail", "accumulator-mismatch", observed
    if next_workload is not None:
        next_expected = next_workload["expected"]
        assert isinstance(next_expected, dict)
        next_numeric_fields = (
            TRANSITION_FIELDS
            | (TRANSITION_NAMESPACE_FIELDS if args.namespace else set())
        ) - {"next_accumulator"}
        if any(
            type(observed[field]) is not int or observed[field] < 0
            for field in next_numeric_fields
        ):
            return "error", "invalid-next-counter", observed
        next_metadata = {
            "next_iterations": next_iterations,
            "next_input_bytes": int(next_workload["actual_bytes"]),
        }
        if any(observed[field] != value for field, value in next_metadata.items()):
            return "fail", "next-metadata-mismatch", observed
        next_counters = ["elements", "attributes", "text_bytes"]
        if args.namespace:
            next_counters.extend(
                ["name_bytes", "value_bytes", *sorted(NAMESPACE_FIELDS)]
            )
        for field in next_counters:
            if observed[f"next_{field}"] != next_expected[field]:
                return "fail", f"next-{field.replace('_', '-')}-mismatch", observed
        next_accumulator = next_expected["checksum"] if consumer == "full" else None
        if observed["next_accumulator"] != next_accumulator:
            return "fail", "next-accumulator-mismatch", observed
    if args.report_memory:
        integer_fields = (
            MEMORY_FIELDS
            | (TRANSITION_MEMORY_FIELDS if next_workload is not None else set())
            | (RELEASE_MEMORY_FIELDS if args.release_memory else set())
        ) - {"parser_storage"}
        if any(
            type(observed[field]) is not int or observed[field] < 0
            for field in integer_fields
        ):
            return "error", "invalid-memory-field", observed
        if observed["input_bytes"] != int(workload["actual_bytes"]):
            return "fail", "input-bytes-mismatch", observed
        expected_storage = "dynamic"
        for argument in program_args:
            if argument.startswith("--parser-storage="):
                expected_storage = argument.removeprefix("--parser-storage=")
        if observed["parser_storage"] != expected_storage:
            return "fail", "parser-storage-mismatch", observed
        allocator_operations = (
            observed["allocator_allocs"]
            + observed["allocator_resizes"]
            + observed["allocator_remaps"]
        )
        if (
            observed["first_allocator_operations"]
            + observed["warm_allocator_operations"]
            != allocator_operations
        ):
            return "fail", "allocator-operations-mismatch", observed
        if observed["live_bytes_after_deinit"] != 0:
            return "fail", "live-bytes-after-deinit", observed
        if observed["live_bytes_before_deinit"] > observed["peak_live_bytes"]:
            return "fail", "live-bytes-exceed-peak", observed
        if (
            not args.release_memory
            and observed["retained_capacity"] > observed["live_bytes_before_deinit"]
        ):
            return "fail", "retained-capacity-exceeds-live-bytes", observed
        expected_storage_bytes = (
            int(workload["actual_bytes"])
            + (int(next_workload["actual_bytes"]) if next_workload is not None else 0)
            if input_model == "resident"
            else chunk_bytes
        )
        if observed["caller_input_storage_bytes"] != expected_storage_bytes:
            return "fail", "caller-input-storage-mismatch", observed
        if (
            next_workload is not None
            and observed["primary_warm_allocator_operations"]
            + observed["next_allocator_operations"]
            != observed["warm_allocator_operations"]
        ):
            return "fail", "warm-phase-operations-mismatch", observed
        if args.release_memory:
            if (
                observed["live_bytes_before_release"] > observed["peak_live_bytes"]
                or observed["retained_capacity"] > observed["live_bytes_before_release"]
            ):
                return "fail", "release-memory-boundary-mismatch", observed
            if any(
                observed[field] != 0
                for field in (
                    "release_allocator_operations",
                    "retained_capacity_after_release",
                    "live_bytes_after_release",
                    "live_bytes_before_deinit",
                )
            ):
                return "fail", "release-memory-not-empty", observed
    if args.report_timing:
        if any(
            type(observed[field]) is not int or observed[field] < 0
            for field in TIMING_FIELDS
        ):
            return "error", "invalid-timing-field", observed
        if (
            (args.iterations == 1 and observed["primary_warm_ns"] != 0)
            or (next_workload is None and observed["next_documents_ns"] != 0)
            or (not args.release_memory and observed["release_ns"] != 0)
        ):
            return "fail", "inactive-timing-phase-not-zero", observed
    return "pass", "-", observed


def check_consumer_parity(
    samples: list[dict[str, object]], namespace: bool
) -> list[str]:
    groups: dict[tuple[str, str, int], dict[str, dict[str, object]]] = {}
    for sample in samples:
        key = (
            str(sample["workload"]),
            str(sample["input"]),
            int(sample["chunk_bytes"]),
        )
        groups.setdefault(key, {})[str(sample["consumer"])] = sample

    fields = [*CONSUMER_PARITY_FIELDS]
    if namespace:
        fields.extend(sorted(NAMESPACE_FIELDS))
    if samples and "next_elements" in samples[0]:
        fields.extend(f"next_{field}" for field in CONSUMER_PARITY_FIELDS)
        if namespace:
            fields.extend(sorted(TRANSITION_NAMESPACE_FIELDS))
    errors: list[str] = []
    for key, by_consumer in sorted(groups.items()):
        if set(by_consumer) != {"minimal", "full"}:
            continue
        minimal = by_consumer["minimal"]
        full = by_consumer["full"]
        for field in fields:
            if minimal[field] != full[field]:
                label = "/".join(map(str, key))
                errors.append(f"{label}: {field} differs between consumers")
    return errors


def check_scale(samples: list[dict[str, object]]) -> list[str]:
    if not samples:
        return ["scale check has no passing samples"]
    groups: dict[tuple[str, str, str, int], list[dict[str, object]]] = {}
    for sample in samples:
        key = (
            str(sample["shape"]),
            str(sample["input"]),
            str(sample["consumer"]),
            int(sample["chunk_bytes"]),
        )
        groups.setdefault(key, []).append(sample)
    errors: list[str] = []
    for key, values in sorted(groups.items()):
        values.sort(key=lambda value: int(value["input_bytes"]))
        sizes = [int(value["input_bytes"]) for value in values]
        label = "/".join(map(str, key))
        if len(sizes) < 4:
            errors.append(f"{label}: scale check needs at least four input sizes")
            continue
        if any(current < previous * 4 for previous, current in pairwise(sizes)):
            errors.append(f"{label}: input sizes are not geometrically increasing")
        for field in sorted(FLAT_MEMORY_FIELDS):
            observed = {int(value[field]) for value in values}
            if len(observed) != 1:
                errors.append(f"{label}: {field} changes with total input bytes")
    return errors


def main() -> int:
    args = parse_args()
    if shutil.which("prlimit") is None:
        print("persistent check requires prlimit from util-linux", file=sys.stderr)
        return 1
    inputs = args.input or ["resident", "stream"]
    consumers = args.consumer or ["minimal", "full"]
    chunks = args.chunk_bytes
    if chunks is None:
        schedules = []
        if "resident" in inputs:
            schedules.append(("resident", 4096))
        if "stream" in inputs:
            schedules.extend(("stream", chunk) for chunk in (1, 7, 4096))
    else:
        schedules = [(input_model, chunk) for input_model in inputs for chunk in chunks]
    if (
        args.iterations <= 0
        or args.max_bytes <= 0
        or args.max_bytes > MAX_WORKLOAD_BYTES
        or args.timeout <= 0
        or not math.isfinite(args.timeout)
        or args.address_space_mib <= 0
        or args.cpu_seconds <= 0
        or args.open_files <= 0
        or args.max_output_bytes <= 0
        or any(chunk <= 0 for _, chunk in schedules)
        or len(inputs) != len(set(inputs))
        or len(consumers) != len(set(consumers))
        or (chunks is not None and len(chunks) != len(set(chunks)))
        or len(args.workload) != len(set(args.workload))
        or len(args.shape) != len(set(args.shape))
        or not args.engine
        or (args.check_scale and not args.report_memory)
        or (args.check_scale and inputs != ["stream"])
        or (args.next_workload is None) != (args.next_iterations is None)
        or (args.next_iterations is not None and args.next_iterations <= 0)
        or (args.next_workload is not None and (len(args.workload) != 1 or args.shape))
        or (args.next_workload is not None and args.next_workload in args.workload)
        or (args.next_workload is not None and args.check_scale)
        or (args.release_memory and not args.report_memory)
    ):
        print("invalid limits, selections, or scale-check options", file=sys.stderr)
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
        print("could not apply persistent process limits", file=sys.stderr)
        return 1

    program = args.program.resolve()
    try:
        results = result_path(args, program)
        results.parent.mkdir(parents=True, exist_ok=True)
        results.unlink(missing_ok=True)
        if not program.is_file() or not os.access(program, os.X_OK):
            raise ValueError(f"missing program: {program}")
        target = read_target(
            args.targets,
            args.target,
            program,
            args.namespace,
            consumers,
            args.report_memory,
        )
        required_tool_features: set[str] = set()
        if args.next_workload is not None:
            required_tool_features.add("transition_schedule")
        if args.report_timing:
            required_tool_features.add("timing_report")
        if args.release_memory:
            required_tool_features.add("release_report")
        missing_tool_features = sorted(
            required_tool_features.difference(target.features)
        )
        if missing_tool_features:
            raise ValueError(
                f"{target.name}: missing target features: "
                + ",".join(missing_tool_features)
            )
        selected_ids = set(args.workload)
        if args.next_workload is not None:
            selected_ids.add(args.next_workload)
        workloads = read_workloads(
            args.manifest,
            args.max_bytes,
            selected_ids,
            set(args.shape),
            args.namespace,
        )
        by_id = {str(workload["id"]): workload for workload in workloads}
        next_workload = by_id.pop(args.next_workload, None)
        if args.next_workload is not None and next_workload is None:
            raise ValueError(f"{args.manifest}: next workload is above the byte limit")
        workloads = list(by_id.values())
        if next_workload is not None and (
            next_workload["expected"] is None
            or any(workload["expected"] is None for workload in workloads)
        ):
            raise ValueError("transition workloads must be benchmark-valid")
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    result_fields = [*RESULT_FIELDS]
    if args.next_workload is not None:
        result_fields.extend(
            sorted(
                (TRANSITION_FIELDS - {"next_iterations"})
                | (TRANSITION_NAMESPACE_FIELDS if args.namespace else set())
            )
        )
    if args.report_memory:
        result_fields.extend(sorted(MEMORY_FIELDS))
        if args.next_workload is not None:
            result_fields.extend(sorted(TRANSITION_MEMORY_FIELDS))
        if args.release_memory:
            result_fields.extend(sorted(RELEASE_MEMORY_FIELDS))
    if args.report_timing:
        result_fields.extend(sorted(TIMING_FIELDS))
    transition_program_args = (
        [
            f"--next-file={next_workload['resolved_path']}",
            f"--next-iterations={args.next_iterations}",
        ]
        if next_workload is not None
        else []
    )
    effective_program_args = [*args.program_arg, *transition_program_args]
    fieldnames = [
        "target",
        "workload",
        "classification",
        "input",
        "consumer",
        "chunk_bytes",
        "iterations",
        *(["next_workload", "next_iterations"] if next_workload is not None else []),
        "program_args",
        "verdict",
        "reason",
        *result_fields,
    ]
    passes = 0
    failures = 0
    unsupported = 0
    failure_reasons: Counter[str] = Counter()
    consumer_samples: list[dict[str, object]] = []
    scale_samples: list[dict[str, object]] = []
    temporary_path: Path | None = None
    consumer_errors: list[str] = []
    scale_errors: list[str] = []
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
                stream, fieldnames, delimiter="\t", lineterminator="\n"
            )
            writer.writeheader()
            for workload in workloads:
                for input_model, chunk_bytes in schedules:
                    for consumer in consumers:
                        required_profile = set(
                            str(workload.get("feature_checks", "")).split(",")
                        ) & {"dtd", "namespaces"}
                        if next_workload is not None:
                            required_profile.update(
                                set(
                                    str(next_workload.get("feature_checks", "")).split(
                                        ","
                                    )
                                )
                                & {"dtd", "namespaces"}
                            )
                        missing = sorted(required_profile.difference(target.features))
                        if missing:
                            verdict = "unsupported-feature"
                            reason = "missing:" + ",".join(missing)
                            observed = None
                        else:
                            verdict, reason, observed = observe(
                                program,
                                args.engine,
                                args.program_arg,
                                workload,
                                next_workload,
                                args.next_iterations or 0,
                                input_model,
                                consumer,
                                chunk_bytes,
                                args,
                            )
                        passes += verdict == "pass"
                        unsupported += verdict == "unsupported-feature"
                        failures += verdict not in {"pass", "unsupported-feature"}
                        if verdict not in {"pass", "unsupported-feature"}:
                            failure_reasons[reason] += 1
                        observed_fields: dict[str, object] = {
                            field: "-" for field in result_fields
                        }
                        if observed is not None:
                            for field in result_fields:
                                if field in observed:
                                    value = observed[field]
                                    observed_fields[field] = (
                                        "null" if value is None else value
                                    )
                            if verdict == "pass":
                                consumer_samples.append(
                                    {
                                        "workload": workload["id"],
                                        "input": input_model,
                                        "consumer": consumer,
                                        "chunk_bytes": chunk_bytes,
                                        **observed,
                                    }
                                )
                            if verdict == "pass" and args.check_scale:
                                scale_samples.append(
                                    {
                                        "shape": workload["shape"],
                                        "input": input_model,
                                        "consumer": consumer,
                                        "chunk_bytes": chunk_bytes,
                                        **observed,
                                    }
                                )
                        writer.writerow(
                            {
                                "target": target.name,
                                "workload": workload["id"],
                                "classification": workload["classification"],
                                "input": input_model,
                                "consumer": consumer,
                                "chunk_bytes": chunk_bytes,
                                "iterations": args.iterations,
                                **(
                                    {
                                        "next_workload": next_workload["id"],
                                        "next_iterations": args.next_iterations,
                                    }
                                    if next_workload is not None
                                    else {}
                                ),
                                "program_args": " ".join(effective_program_args) or "-",
                                "verdict": verdict,
                                "reason": reason,
                                **observed_fields,
                            }
                        )
        if {"minimal", "full"}.issubset(consumers):
            consumer_errors = check_consumer_parity(consumer_samples, args.namespace)
        scale_errors = check_scale(scale_samples) if args.check_scale else []
        if failures or consumer_errors or scale_errors or not passes:
            temporary_path.unlink(missing_ok=True)
        else:
            temporary_path.replace(results)
    except OSError as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        print(error, file=sys.stderr)
        return 1
    total_failures = failures + len(consumer_errors)
    print(
        f"{target.name}: {passes} pass, {unsupported} unsupported, "
        f"{total_failures} fail"
    )
    for reason, count in sorted(failure_reasons.items()):
        print(f"failure {reason}: {count}", file=sys.stderr)
    for error in consumer_errors:
        print(f"failure consumer-parity: {error}", file=sys.stderr)
    if args.check_scale and not scale_errors:
        print(f"{target.name} streaming scale: {len(scale_samples)} samples pass")
    for error in scale_errors:
        print(error, file=sys.stderr)
    if failures or consumer_errors or scale_errors or not passes:
        print("results not published", file=sys.stderr)
        return 1
    print(f"results: {results}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
