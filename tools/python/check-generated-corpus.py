#!/usr/bin/env python3
"""Qualify common-summary and owned-document adapters against generated XML."""

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
NAMESPACE_SCHEMA = "z-xml-namespace-benchmark-v1"
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
WORK_LANES = {
    "event",
    "dom",
    "partial-dom",
    "subset",
    "lexical",
    "structural-index",
    "validated",
}
INPUT_MODELS = {"streaming-reader", "file-reader", "whole-file"}
SUMMARY_LANES = {
    "event": {"wf", "partial"},
    "partial-dom": {"partial"},
    "subset": {"partial", "subset"},
}
DOCUMENT_SUMMARY_COLUMNS = [
    "nodes",
    "elements",
    "attributes",
    "text_nodes",
    "text_bytes",
    "comments",
    "processing_instructions",
    "max_depth",
    "common_checksum",
    "traversal_checksum",
]
DOCUMENT_SUMMARY_FIELDS = set(DOCUMENT_SUMMARY_COLUMNS)
NAMESPACE_DOCUMENT_SUMMARY_COLUMNS = [
    *DOCUMENT_SUMMARY_COLUMNS[:7],
    "namespace_declarations",
    "max_depth",
    "common_checksum",
    "expanded_name_checksum",
    "traversal_checksum",
]
NAMESPACE_DOCUMENT_SUMMARY_FIELDS = set(NAMESPACE_DOCUMENT_SUMMARY_COLUMNS)
DOCUMENT_TIMING_FIELDS = {
    "build_ns",
    "traversal_ns",
    "iterations",
    "elements",
    "checksum",
}
CONSTRUCTION_FIELDS = {"constructed"}
Z_XML_MEMORY_COLUMNS = [
    "nodes",
    "attributes",
    "namespace_declarations",
    "string_bytes",
    "node_capacity_bytes",
    "attribute_capacity_bytes",
    "namespace_declaration_capacity_bytes",
    "string_capacity_bytes",
    "metadata_capacity_bytes",
    "active_owned_bytes",
    "growth_slack_bytes",
    "retained_capacity_bytes",
    "construction_requested_bytes",
    "construction_temporary_bytes",
    "construction_peak_bytes",
    "construction_allocator_operations",
    "reader_requested_bytes",
    "reader_temporary_bytes",
    "reader_peak_bytes",
    "reader_retained_bytes",
    "reader_allocator_operations",
    "reader_live_after_deinit_bytes",
    "caller_input_storage_bytes",
    "traversal_scratch_peak_bytes",
    "traversal_allocator_operations",
    "traversal_live_after_deinit_bytes",
    "live_after_deinit_bytes",
]
Z_XML_MEMORY_FIELDS = set(Z_XML_MEMORY_COLUMNS)
Z_XML_RESULT_MEMORY_COLUMNS = [
    "owned_nodes",
    "owned_attributes",
    "owned_namespace_declarations",
    "owned_string_bytes",
    *Z_XML_MEMORY_COLUMNS[4:],
]
PEER_MEMORY_FIELDS = {
    "nodes",
    "attributes",
    "retained_library_bytes",
    "construction_peak_library_bytes",
    "construction_allocator_operations",
    "traversal_scratch_peak_bytes",
    "traversal_allocator_operations",
    "live_after_deinit_bytes",
}


@dataclass(frozen=True)
class Target:
    name: str
    executable: Path
    processor_class: str
    features: frozenset[str]
    work_lane: str
    input_model: str


@dataclass(frozen=True)
class DocumentObservation:
    summary: dict[str, object]
    memory: dict[str, int]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument(
        "--summary-lane",
        action="append",
        choices=sorted(SUMMARY_LANES),
        default=[],
    )
    parser.add_argument("--document-oracle", type=Path)
    parser.add_argument(
        "--document-operation",
        choices=("construction", "traversal"),
        default="construction",
    )
    parser.add_argument("--namespace", action="store_true")
    parser.add_argument("--shape", action="append", default=[])
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
    oracle = args.document_oracle.resolve() if args.document_oracle else None
    if (
        args.results.is_symlink()
        or resolved in {manifest, targets, oracle}
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


def read_targets(
    path: Path,
    bin_dir: Path,
    selected: set[str],
    document_mode: bool,
    summary_lanes: set[str],
) -> list[Target]:
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
        lane_matches = (
            work_lane == "dom"
            if document_mode
            else work_lane in summary_lanes
            and processor_class in SUMMARY_LANES[work_lane]
        )
        if not lane_matches:
            if selected:
                lane = (
                    "document"
                    if document_mode
                    else " or ".join(sorted(summary_lanes)) + " summary"
                )
                raise ValueError(
                    f"{name}: target is not declared for the {lane} input lane"
                )
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
        lane = (
            "document"
            if document_mode
            else " or ".join(sorted(summary_lanes)) + " summary"
        )
        raise ValueError(f"{path}: no {lane} targets selected")
    return targets


def read_workloads(
    manifest: Path,
    max_bytes: int,
    selected_shapes: set[str],
    namespace: bool,
) -> list[dict[str, str]]:
    if namespace:
        return read_namespace_workloads(manifest, max_bytes, selected_shapes)
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
        if size <= max_bytes and (
            not selected_shapes or row["shape"] in selected_shapes
        ):
            row["resolved_path"] = str(path)
            selected_rows.append(row)
    if not selected_rows:
        raise ValueError(f"{manifest}: no workloads are at or below --max-bytes")
    missing_shapes = selected_shapes.difference(row["shape"] for row in selected_rows)
    if missing_shapes:
        raise ValueError(
            f"{manifest}: missing selected shapes: " + ",".join(sorted(missing_shapes))
        )
    return selected_rows


def read_namespace_workloads(
    manifest: Path, max_bytes: int, selected_shapes: set[str]
) -> list[dict[str, str]]:
    with manifest.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    comments = [line[1:].strip() for line in lines if line.startswith("#")]
    if comments != [NAMESPACE_SCHEMA]:
        raise ValueError(f"{manifest}: invalid namespace-corpus identity")
    reader = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    columns = [
        "id",
        "path",
        "shape",
        "actual_bytes",
        "classification",
        "expected_summary",
    ]
    if reader.fieldnames != columns:
        raise ValueError(f"{manifest}: invalid namespace-corpus columns")
    rows = list(reader)
    if not rows:
        raise ValueError(f"{manifest}: namespace manifest is empty")

    root = manifest.parent.resolve()
    selected_rows: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    seen_paths: set[Path] = set()
    expected_fields = {
        "elements",
        "attributes",
        "text_bytes",
        "name_bytes",
        "value_bytes",
        "namespace_declarations",
        "namespace_uri_bytes",
        "local_name_bytes",
        "prefix_bytes",
        "checksum",
    }
    for line_number, row in enumerate(rows, 3):
        if None in row or any(value is None or value == "" for value in row.values()):
            raise ValueError(f"{manifest}:{line_number}: invalid workload row")
        item_id = row["id"]
        if item_id in seen_ids:
            raise ValueError(
                f"{manifest}:{line_number}: duplicate workload ID {item_id}"
            )
        seen_ids.add(item_id)
        path = (root / row["path"]).resolve()
        if not path.is_relative_to(root):
            raise ValueError(f"{item_id}: path escapes namespace corpus")
        if path in seen_paths:
            raise ValueError(f"{item_id}: duplicate workload path")
        seen_paths.add(path)
        try:
            actual_bytes = int(row["actual_bytes"])
            expected = decode_json(row["expected_summary"])
        except ValueError as error:
            raise ValueError(f"{item_id}: invalid namespace metadata") from error
        if (
            actual_bytes <= 0
            or actual_bytes > MAX_WORKLOAD_BYTES
            or not path.is_file()
            or path.stat().st_size != actual_bytes
            or row["shape"] != "namespace-churn"
            or row["classification"] != "benchmark-valid"
            or not isinstance(expected, dict)
            or set(expected) != expected_fields
        ):
            raise ValueError(f"{item_id}: invalid namespace workload")
        integer_fields = expected_fields.difference({"checksum"})
        if any(
            type(expected[field]) is not int or expected[field] < 0
            for field in integer_fields
        ):
            raise ValueError(f"{item_id}: invalid namespace summary values")
        checksum = expected["checksum"]
        if not isinstance(checksum, str) or len(checksum) != 16:
            raise ValueError(f"{item_id}: invalid namespace checksum")
        try:
            checksum_value = int(checksum, 16)
        except ValueError as error:
            raise ValueError(f"{item_id}: invalid namespace checksum") from error
        if checksum != f"{checksum_value:016x}":
            raise ValueError(f"{item_id}: invalid namespace checksum")
        if actual_bytes <= max_bytes and (
            not selected_shapes or row["shape"] in selected_shapes
        ):
            row["feature_checks"] = "document,namespaces,attributes"
            row["resolved_path"] = str(path)
            selected_rows.append(row)
    if not selected_rows:
        raise ValueError(f"{manifest}: no workloads are at or below --max-bytes")
    missing_shapes = selected_shapes.difference(row["shape"] for row in selected_rows)
    if missing_shapes:
        raise ValueError(
            f"{manifest}: missing selected shapes: " + ",".join(sorted(missing_shapes))
        )
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


def run_json_adapter(
    executable: Path,
    adapter_args: list[str],
    workload: dict[str, str],
    args: argparse.Namespace,
) -> tuple[dict[str, object] | None, str]:
    command = [
        "prlimit",
        f"--as={args.address_space_mib * 1024 * 1024}",
        f"--cpu={args.cpu_seconds}",
        f"--nofile={args.open_files}",
        f"--fsize={args.max_output_bytes}",
        "--",
        str(executable),
        *adapter_args,
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
        return None, "timeout"
    except OSError as error:
        return None, f"exec:{error}"
    if len(output) > args.max_output_bytes or len(diagnostic) > args.max_output_bytes:
        return None, "output-limit"
    if completed.returncode in {-signal.SIGXFSZ, 128 + signal.SIGXFSZ}:
        return None, "output-limit"
    if completed.returncode != 0:
        return None, f"status-{completed.returncode}"
    if diagnostic:
        return None, "unexpected-stderr"
    try:
        decoded = decode_json(output)
    except (UnicodeDecodeError, ValueError):
        return None, "invalid-json"
    if not isinstance(decoded, dict):
        return None, "result-not-object"
    return decoded, "-"


def validate_document_summary(
    summary: dict[str, object], workload: dict[str, str], namespace: bool
) -> str | None:
    fields = NAMESPACE_DOCUMENT_SUMMARY_FIELDS if namespace else DOCUMENT_SUMMARY_FIELDS
    if set(summary) != fields:
        return "summary-fields"
    checksum_fields = {"common_checksum", "traversal_checksum"}
    if namespace:
        checksum_fields.add("expanded_name_checksum")
    integer_fields = fields.difference(checksum_fields)
    if any(
        type(summary[field]) is not int or summary[field] < 0
        for field in integer_fields
    ):
        return "summary-values"
    for field in checksum_fields:
        checksum = summary[field]
        if not isinstance(checksum, str) or len(checksum) != 16:
            return "summary-checksum"
        try:
            checksum_value = int(checksum, 16)
        except ValueError:
            return "summary-checksum"
        if checksum != f"{checksum_value:016x}":
            return "summary-checksum"
    if summary["nodes"] != (
        1
        + summary["elements"]
        + summary["text_nodes"]
        + summary["comments"]
        + summary["processing_instructions"]
    ):
        return "summary-node-count"
    if summary["elements"] == 0:
        if summary["max_depth"] != 0:
            return "summary-depth"
    elif not 1 <= summary["max_depth"] <= summary["elements"]:
        return "summary-depth"
    expected = decode_json(workload["expected_summary"])
    if not isinstance(expected, dict):
        return "manifest-summary"
    if namespace:
        matches = (
            summary["elements"] == expected["elements"]
            and summary["attributes"] == expected["attributes"]
            and summary["text_bytes"] == expected["text_bytes"]
            and summary["namespace_declarations"] == expected["namespace_declarations"]
            and summary["expanded_name_checksum"] == expected["checksum"]
        )
    else:
        matches = (
            summary["elements"] == expected["elements"]
            and summary["attributes"] == expected["attributes"]
            and summary["text_bytes"] == expected["text_bytes"]
            and summary["common_checksum"] == expected["checksum"]
        )
    if not matches:
        return "common-summary-mismatch"
    return None


def validate_construction(value: dict[str, object]) -> str | None:
    if set(value) != CONSTRUCTION_FIELDS or value["constructed"] is not True:
        return "construction-result"
    return None


def validate_document_timing(
    timing: dict[str, object], summary: dict[str, object]
) -> str | None:
    if set(timing) != DOCUMENT_TIMING_FIELDS:
        return "timing-fields"
    if any(
        type(timing[field]) is not int or timing[field] < 0
        for field in ("build_ns", "traversal_ns", "iterations", "elements")
    ):
        return "timing-values"
    if timing["iterations"] != 1:
        return "timing-iterations"
    if timing["elements"] != summary["elements"]:
        return "timing-elements"
    if timing["checksum"] != summary["traversal_checksum"]:
        return "timing-checksum"
    return None


def validate_z_xml_memory(
    memory: dict[str, object], summary: dict[str, object]
) -> tuple[DocumentObservation | None, str]:
    if set(memory) != Z_XML_MEMORY_FIELDS:
        return None, "memory-fields"
    if any(type(value) is not int or value < 0 for value in memory.values()):
        return None, "memory-values"
    if memory["nodes"] != summary["nodes"]:
        return None, "memory-nodes"
    if memory["attributes"] != summary["attributes"]:
        return None, "memory-attributes"
    expected_namespaces = summary.get("namespace_declarations", 0)
    if memory["namespace_declarations"] != expected_namespaces:
        return None, "memory-namespaces"
    capacity_sum = (
        memory["node_capacity_bytes"]
        + memory["attribute_capacity_bytes"]
        + memory["namespace_declaration_capacity_bytes"]
        + memory["string_capacity_bytes"]
        + memory["metadata_capacity_bytes"]
    )
    if capacity_sum != memory["retained_capacity_bytes"]:
        return None, "memory-capacity-sum"
    if (
        memory["retained_capacity_bytes"] <= 0
        or memory["active_owned_bytes"] <= 0
        or memory["active_owned_bytes"] + memory["growth_slack_bytes"]
        != memory["retained_capacity_bytes"]
        or memory["string_bytes"] > memory["string_capacity_bytes"]
    ):
        return None, "memory-retained"
    if memory["construction_peak_bytes"] < memory["retained_capacity_bytes"]:
        return None, "memory-construction-peak"
    if memory["construction_allocator_operations"] <= 0:
        return None, "memory-construction-operations"
    if (
        memory["construction_requested_bytes"]
        != memory["retained_capacity_bytes"] + memory["construction_temporary_bytes"]
        or memory["reader_requested_bytes"]
        != memory["reader_retained_bytes"] + memory["reader_temporary_bytes"]
        or memory["reader_peak_bytes"] < memory["reader_retained_bytes"]
        or memory["reader_allocator_operations"] <= 0
        or memory["caller_input_storage_bytes"] != 64 * 1024
        or memory["reader_live_after_deinit_bytes"] != 0
        or memory["traversal_live_after_deinit_bytes"] != 0
        or memory["live_after_deinit_bytes"] != 0
    ):
        return None, "memory-lifecycle"
    normalized = {
        "retained_bytes": memory["retained_capacity_bytes"],
        "owned_nodes": memory["nodes"],
        "owned_attributes": memory["attributes"],
        "owned_namespace_declarations": memory["namespace_declarations"],
        "owned_string_bytes": memory["string_bytes"],
        **{field: memory[field] for field in Z_XML_MEMORY_COLUMNS[4:]},
    }
    return (
        DocumentObservation(
            summary=summary,
            memory=normalized,
        ),
        "-",
    )


def validate_peer_memory(
    memory: dict[str, object], summary: dict[str, object]
) -> tuple[DocumentObservation | None, str]:
    if set(memory) != PEER_MEMORY_FIELDS:
        return None, "memory-fields"
    if any(type(value) is not int or value < 0 for value in memory.values()):
        return None, "memory-values"
    if memory["nodes"] != summary["nodes"]:
        return None, "memory-nodes"
    if memory["attributes"] != summary["attributes"]:
        return None, "memory-attributes"
    if memory["retained_library_bytes"] <= 0:
        return None, "memory-retained"
    if memory["construction_peak_library_bytes"] < memory["retained_library_bytes"]:
        return None, "memory-construction-peak"
    if memory["construction_allocator_operations"] <= 0:
        return None, "memory-construction-operations"
    if (
        memory["traversal_scratch_peak_bytes"] != 0
        or memory["traversal_allocator_operations"] != 0
    ):
        return None, "memory-traversal-allocation"
    if memory["live_after_deinit_bytes"] != 0:
        return None, "memory-live-after-deinit"
    return (
        DocumentObservation(
            summary=summary,
            memory={
                "retained_bytes": memory["retained_library_bytes"],
                "construction_peak_bytes": memory["construction_peak_library_bytes"],
                "construction_allocator_operations": memory[
                    "construction_allocator_operations"
                ],
                "traversal_scratch_peak_bytes": memory["traversal_scratch_peak_bytes"],
                "traversal_allocator_operations": memory[
                    "traversal_allocator_operations"
                ],
                "live_after_deinit_bytes": memory["live_after_deinit_bytes"],
            },
        ),
        "-",
    )


def observe_document(
    executable: Path,
    workload: dict[str, str],
    args: argparse.Namespace,
    peer: bool,
    namespace: bool,
) -> tuple[DocumentObservation | None, str]:
    namespace_args = ["--namespaces=process"] if namespace else []
    summary, reason = run_json_adapter(executable, namespace_args, workload, args)
    if summary is None:
        return None, f"summary-{reason}"
    reason = validate_document_summary(summary, workload, namespace)
    if reason is not None:
        return None, reason
    construction, reason = run_json_adapter(
        executable, ["--construction", *namespace_args], workload, args
    )
    if construction is None:
        return None, f"construction-{reason}"
    reason = validate_construction(construction)
    if reason is not None:
        return None, reason
    timing, reason = run_json_adapter(
        executable, ["--timing", *namespace_args], workload, args
    )
    if timing is None:
        return None, f"timing-{reason}"
    reason = validate_document_timing(timing, summary)
    if reason is not None:
        return None, reason
    memory, reason = run_json_adapter(
        executable, ["--memory", *namespace_args], workload, args
    )
    if memory is None:
        return None, f"memory-{reason}"
    if peer:
        return validate_peer_memory(memory, summary)
    return validate_z_xml_memory(memory, summary)


def write_document_row(
    writer: csv.DictWriter,
    target: Target,
    workload: dict[str, str],
    observation: DocumentObservation | None,
    verdict: str,
    reason: str,
    namespace: bool,
    operation: str,
) -> None:
    program_args = "--construction" if operation == "construction" else "--timing"
    if namespace:
        program_args += " --namespaces=process"
    row: dict[str, object] = {
        "target": target.name,
        "work_lane": target.work_lane,
        "input_model": target.input_model,
        "workload": workload["id"],
        "classification": workload["classification"],
        "program_args": program_args,
        "verdict": verdict,
        "reason": reason,
    }
    if observation is not None:
        row.update(observation.summary)
        row.update(observation.memory)
    writer.writerow(row)


def check_documents(
    args: argparse.Namespace,
    results: Path,
    targets: list[Target],
    workloads: list[dict[str, str]],
) -> int:
    oracle_observations: dict[str, DocumentObservation] = {}
    for workload in workloads:
        observation, reason = observe_document(
            args.document_oracle, workload, args, peer=False, namespace=args.namespace
        )
        if observation is None:
            print(f"document oracle {workload['id']}: {reason}", file=sys.stderr)
            print("results not published", file=sys.stderr)
            return 1
        oracle_observations[workload["id"]] = observation

    summary_columns = (
        NAMESPACE_DOCUMENT_SUMMARY_COLUMNS
        if args.namespace
        else DOCUMENT_SUMMARY_COLUMNS
    )
    fieldnames = [
        "target",
        "work_lane",
        "input_model",
        "workload",
        "classification",
        "program_args",
        "verdict",
        "reason",
        *summary_columns,
        "retained_bytes",
        *Z_XML_RESULT_MEMORY_COLUMNS,
    ]
    totals: Counter[str] = Counter()
    failure_reasons: Counter[str] = Counter()
    temporary_path: Path | None = None
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
                        observation = None
                        verdict = "fail"
                        reason = "missing:" + ",".join(missing)
                    else:
                        peer = not target.executable.samefile(args.document_oracle)
                        observation, reason = observe_document(
                            target.executable,
                            workload,
                            args,
                            peer=peer,
                            namespace=args.namespace,
                        )
                        if observation is None:
                            verdict = "error"
                        elif (
                            observation.summary
                            != oracle_observations[workload["id"]].summary
                        ):
                            verdict = "fail"
                            reason = "document-summary-mismatch"
                        else:
                            verdict = "pass"
                    counts[verdict] += 1
                    totals[verdict] += 1
                    if verdict != "pass":
                        failure_reasons[reason] += 1
                    write_document_row(
                        writer,
                        target,
                        workload,
                        observation,
                        verdict,
                        reason,
                        args.namespace,
                        args.document_operation,
                    )
                print(
                    f"{target.name}: pass={counts['pass']} fail={counts['fail']} "
                    f"error={counts['error']}"
                )
        if totals["fail"] or totals["error"]:
            temporary_path.unlink(missing_ok=True)
        else:
            temporary_path.replace(results)
    except OSError as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        print(error, file=sys.stderr)
        return 1
    print(f"total: pass={totals['pass']} fail={totals['fail']} error={totals['error']}")
    for reason, count in sorted(failure_reasons.items()):
        print(f"failure {reason}: {count}", file=sys.stderr)
    if totals["fail"] or totals["error"]:
        print("results not published", file=sys.stderr)
        return 1
    print(f"results: {results}")
    return 0


def main() -> int:
    args = parse_args()
    document_mode = args.document_oracle is not None
    summary_lanes = set(args.summary_lane or ["event"])
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
        or len(args.shape) != len(set(args.shape))
        or (args.summary_lane and len(args.summary_lane) != len(summary_lanes))
        or (document_mode and (not args.target or not args.shape))
        or (document_mode and bool(args.summary_lane))
        or (not document_mode and bool(args.shape))
        or (args.namespace and not document_mode)
        or (not document_mode and args.document_operation != "construction")
    ):
        print("invalid limits, timeout, target, or shape selection", file=sys.stderr)
        return 64
    try:
        results = result_path(args)
        results.parent.mkdir(parents=True, exist_ok=True)
        results.unlink(missing_ok=True)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    if document_mode and (
        not args.document_oracle.is_file()
        or not os.access(args.document_oracle, os.X_OK)
    ):
        print(f"missing document oracle: {args.document_oracle}", file=sys.stderr)
        return 1
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
        targets = read_targets(
            args.targets,
            args.bin_dir,
            set(args.target),
            document_mode,
            summary_lanes,
        )
        workloads = read_workloads(
            args.manifest, args.max_bytes, set(args.shape), args.namespace
        )
        if document_mode and any(
            workload["classification"] != "benchmark-valid" for workload in workloads
        ):
            raise ValueError("document qualification requires valid workloads")
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    if document_mode:
        return check_documents(args, results, targets, workloads)

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
