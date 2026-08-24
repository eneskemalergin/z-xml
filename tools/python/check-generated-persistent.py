#!/usr/bin/env python3
"""Qualify one shared-protocol persistent adapter against a generated manifest."""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
from itertools import pairwise
from pathlib import Path

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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--program", type=Path, required=True)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--program-arg", action="append", default=[])
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
    parser.add_argument("--report-memory", action="store_true")
    parser.add_argument("--check-scale", action="store_true")
    return parser.parse_args()


def read_workloads(
    manifest: Path,
    max_bytes: int,
    selected_ids: set[str],
    selected_shapes: set[str],
    namespace: bool,
) -> list[dict[str, object]]:
    with manifest.open(encoding="utf-8", newline="") as stream:
        rows = list(
            csv.DictReader(
                (line for line in stream if not line.startswith("#")), delimiter="\t"
            )
        )
    required = {
        "id",
        "path",
        "shape",
        "actual_bytes",
        "classification",
        "expected_summary",
    }
    if not rows or not required.issubset(rows[0]):
        raise ValueError(f"{manifest}: missing persistent qualification fields")

    root = manifest.parent.resolve()
    selected: list[dict[str, object]] = []
    known_ids: set[str] = set()
    known_shapes: set[str] = set()
    for row in rows:
        known_ids.add(row["id"])
        known_shapes.add(row["shape"])
        if selected_ids and row["id"] not in selected_ids:
            continue
        if selected_shapes and row["shape"] not in selected_shapes:
            continue
        size = int(row["actual_bytes"])
        if size > max_bytes:
            continue
        path = (root / row["path"]).resolve()
        try:
            path.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{row['id']}: path escapes generated corpus") from error
        if path.stat().st_size != size:
            raise ValueError(f"{row['id']}: byte size differs from manifest")
        expected = None
        if row["classification"] == "benchmark-valid":
            expected = json.loads(row["expected_summary"])
            expected_fields = (
                NAMESPACE_SUMMARY_FIELDS if namespace else COMMON_SUMMARY_FIELDS
            )
            if set(expected) != expected_fields:
                raise ValueError(f"{row['id']}: invalid expected summary")
        elif row["classification"] != "not-well-formed":
            raise ValueError(f"{row['id']}: unsupported classification")
        selected.append({**row, "resolved_path": path, "expected": expected})
    unknown = selected_ids.difference(known_ids)
    if unknown:
        raise ValueError(f"{manifest}: unknown workloads: {','.join(sorted(unknown))}")
    unknown_shapes = selected_shapes.difference(known_shapes)
    if unknown_shapes:
        raise ValueError(
            f"{manifest}: unknown shapes: {','.join(sorted(unknown_shapes))}"
        )
    if not selected:
        raise ValueError(f"{manifest}: no workload at or below the byte limit")
    return selected


def observe(
    program: Path,
    engine: str,
    program_args: list[str],
    workload: dict[str, object],
    input_model: str,
    consumer: str,
    chunk_bytes: int,
    iterations: int,
    timeout: float,
    namespace: bool,
    report_memory: bool,
) -> tuple[str, str, dict[str, object] | None]:
    command = [
        str(program),
        *program_args,
        f"--input={input_model}",
        f"--consumer={consumer}",
        f"--iterations={iterations}",
        f"--chunk-bytes={chunk_bytes}",
    ]
    if report_memory:
        command.append("--report-memory")
    command.append(str(workload["resolved_path"]))
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return "error", "timeout", None
    except OSError as error:
        return "error", str(error), None

    if workload["classification"] == "not-well-formed":
        return (
            ("pass", "-", None)
            if completed.returncode == 2
            else (
                "fail",
                f"expected-status-2-observed-{completed.returncode}",
                None,
            )
        )
    if completed.returncode != 0:
        return "error", f"status-{completed.returncode}", None

    try:
        observed = json.loads(completed.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "error", "invalid-json", None
    expected_output_fields = (
        EXPECTED_FIELDS
        | (NAMESPACE_FIELDS if namespace else set())
        | (MEMORY_FIELDS if report_memory else set())
    )
    if not isinstance(observed, dict) or set(observed) != expected_output_fields:
        return "error", "unexpected-fields", None
    metadata = {
        "engine": engine,
        "input": input_model,
        "consumer": consumer,
        "iterations": iterations,
        "chunk_bytes": chunk_bytes,
    }
    if any(observed[key] != value for key, value in metadata.items()):
        return "fail", "metadata-mismatch", observed

    expected = workload["expected"]
    assert isinstance(expected, dict)
    counters = ["elements", "attributes", "text_bytes"]
    if namespace:
        counters.extend(["name_bytes", "value_bytes", *sorted(NAMESPACE_FIELDS)])
    for field in counters:
        if observed[field] != expected[field]:
            return "fail", f"{field}-mismatch", observed
    accumulator = expected["checksum"] if consumer == "full" else None
    if observed["accumulator"] != accumulator:
        return "fail", "accumulator-mismatch", observed
    for field in ("name_bytes", "value_bytes", "fragments"):
        if type(observed[field]) is not int or observed[field] < 0:
            return "error", f"invalid-{field}", observed
    if report_memory:
        integer_fields = MEMORY_FIELDS - {"parser_storage"}
        for field in integer_fields:
            if type(observed[field]) is not int or observed[field] < 0:
                return "error", f"invalid-{field}", observed
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
        if observed["retained_capacity"] > observed["live_bytes_before_deinit"]:
            return "fail", "retained-capacity-exceeds-live-bytes", observed
    return "pass", "-", observed


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
    inputs = args.input or ["resident", "stream"]
    consumers = args.consumer or ["minimal", "full"]
    chunks = args.chunk_bytes or [1, 7, 4096, 65536]
    if (
        args.iterations <= 0
        or args.max_bytes <= 0
        or args.timeout <= 0
        or any(chunk <= 0 for chunk in chunks)
        or (args.check_scale and not args.report_memory)
        or (args.check_scale and inputs != ["stream"])
    ):
        print(
            "invalid limits, chunks, or scale-check options",
            file=sys.stderr,
        )
        return 64

    program = args.program.resolve()
    if not program.is_file():
        print(f"missing program: {program}", file=sys.stderr)
        return 1
    try:
        workloads = read_workloads(
            args.manifest,
            args.max_bytes,
            set(args.workload),
            set(args.shape),
            args.namespace,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1

    args.results.parent.mkdir(parents=True, exist_ok=True)
    result_fields = (
        [*RESULT_FIELDS, *sorted(MEMORY_FIELDS)]
        if args.report_memory
        else RESULT_FIELDS
    )
    fieldnames = [
        "target",
        "workload",
        "classification",
        "input",
        "consumer",
        "chunk_bytes",
        "iterations",
        "program_args",
        "verdict",
        "reason",
        *result_fields,
    ]
    passes = 0
    failures = 0
    scale_samples: list[dict[str, object]] = []
    with args.results.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for workload in workloads:
            for input_model in inputs:
                for consumer in consumers:
                    for chunk_bytes in chunks:
                        verdict, reason, observed = observe(
                            program,
                            args.engine,
                            args.program_arg,
                            workload,
                            input_model,
                            consumer,
                            chunk_bytes,
                            args.iterations,
                            args.timeout,
                            args.namespace,
                            args.report_memory,
                        )
                        passes += verdict == "pass"
                        failures += verdict != "pass"
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
                                "target": f"{args.engine}-persistent",
                                "workload": workload["id"],
                                "classification": workload["classification"],
                                "input": input_model,
                                "consumer": consumer,
                                "chunk_bytes": chunk_bytes,
                                "iterations": args.iterations,
                                "program_args": " ".join(args.program_arg) or "-",
                                "verdict": verdict,
                                "reason": reason,
                                **observed_fields,
                            }
                        )
    print(
        f"{args.engine} persistent generated qualification: "
        f"{passes} pass, {failures} fail"
    )
    scale_errors = check_scale(scale_samples) if args.check_scale else []
    if args.check_scale and not scale_errors:
        print(f"{args.engine} streaming scale: {len(scale_samples)} samples pass")
    for error in scale_errors:
        print(error, file=sys.stderr)
    print(f"results: {args.results}")
    return 1 if failures or scale_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
