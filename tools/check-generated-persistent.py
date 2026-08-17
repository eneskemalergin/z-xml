#!/usr/bin/env python3
"""Qualify one shared-protocol persistent adapter against a generated manifest."""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
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
) -> tuple[str, str, dict[str, object] | None]:
    command = [
        str(program),
        *program_args,
        f"--input={input_model}",
        f"--consumer={consumer}",
        f"--iterations={iterations}",
        f"--chunk-bytes={chunk_bytes}",
        str(workload["resolved_path"]),
    ]
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return "error", "timeout", None
    except OSError as error:
        return "error", str(error), None

    if workload["classification"] == "not-well-formed":
        return ("pass", "-", None) if completed.returncode == 2 else (
            "fail",
            f"expected-status-2-observed-{completed.returncode}",
            None,
        )
    if completed.returncode != 0:
        return "error", f"status-{completed.returncode}", None

    try:
        observed = json.loads(completed.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "error", "invalid-json", None
    expected_output_fields = EXPECTED_FIELDS | (NAMESPACE_FIELDS if namespace else set())
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
    return "pass", "-", observed


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
    ):
        print("iterations, byte limits, timeout, and chunks must be positive", file=sys.stderr)
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
        *RESULT_FIELDS,
    ]
    passes = 0
    failures = 0
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
                        )
                        passes += verdict == "pass"
                        failures += verdict != "pass"
                        observed_fields: dict[str, object] = {
                            field: "-" for field in RESULT_FIELDS
                        }
                        if observed is not None:
                            for field in RESULT_FIELDS:
                                if field in observed:
                                    value = observed[field]
                                    observed_fields[field] = (
                                        "null" if value is None else value
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
    print(f"results: {args.results}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
