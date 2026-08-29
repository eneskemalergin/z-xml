#!/usr/bin/env python3
"""Validate benchmark shapes, semantic oracles, and input ownership."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

SCHEMA = "z-xml-shape-matrix-v1"
ORACLE_SCHEMA = "z-xml-oracles-v1"
PLAN_SCHEMA = "z-xml-benchmark-plan-v1"
FIXTURE_SCHEMA = "z-xml-fixtures-v2"
WRITER_TARGET_SCHEMA = "z-xml-writer-targets-v1"
EXPECTED_COLUMNS = [
    "id",
    "family",
    "lane",
    "profile",
    "input_models",
    "seed_fixture",
    "generator",
    "size_plan",
    "expected",
    "oracle",
    "status",
    "notes",
]
ORACLE_COLUMNS = ["id", "lane", "format", "fields", "status", "notes"]
VALID_LANES = {
    "event",
    "dom",
    "validated",
    "writer",
    "event,dom",
    "event,dom,validated",
}
VALID_EXPECTATIONS = {"accept", "reject", "resource-limit", "emit"}
VALID_STATUSES = {"ready", "planned"}
VALID_ORACLE_FORMATS = {"compact-json", "manifest-columns", "tsv"}
READER_INPUT_MODELS = {"whole-file", "resident", "stream"}
WRITER_INPUT_MODELS = {
    "buffered-sink",
    "unbuffered-sink",
    "one-byte-sink",
    "short-sink",
}
WRITER_SHAPES = {
    "writer-attributes": (
        "writer-output-v1",
        {"buffered-sink", "unbuffered-sink"},
    ),
    "writer-unchanged-text": (
        "writer-output-v1",
        {"buffered-sink", "unbuffered-sink"},
    ),
    "writer-escaped-text": (
        "writer-output-v1",
        {"buffered-sink", "unbuffered-sink"},
    ),
    "writer-fragmented-text": (
        "writer-output-v1",
        {"buffered-sink", "unbuffered-sink"},
    ),
    "writer-namespace-depth": (
        "writer-namespace-output-v1",
        {"buffered-sink", "unbuffered-sink"},
    ),
    "writer-short-sink": (
        "writer-output-v1",
        {"one-byte-sink", "short-sink"},
    ),
    "writer-repeated-documents": (
        "writer-output-v1",
        {"buffered-sink", "unbuffered-sink"},
    ),
}
READY_GENERATORS = {
    "attributes-varied",
    "deep",
    "escaped",
    "markup",
    "mixed",
    "records",
    "rejection",
    "text",
    "unicode",
    "validation-identifiers",
    "validation-models",
} | set(WRITER_SHAPES)
MAX_BENCHMARK_BYTES = 1024 * 1024 * 1024
WRITER_TARGET_COLUMNS = [
    "name",
    "executable",
    "processor_class",
    "features",
    "work_lane",
    "input_model",
]
REQUIRED_WRITER_FEATURES = {
    "buffered_sink",
    "exact_output_tests",
    "manifest_shapes",
    "memory_report",
    "reader_oracle",
    "short_sink",
    "sink_calls",
    "writer_protocol",
}


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--matrix",
        type=Path,
        default=root / "bench" / "shapes.tsv",
    )
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=root / "fixture" / "manifest.tsv",
    )
    parser.add_argument(
        "--oracles",
        type=Path,
        default=root / "bench" / "oracles.tsv",
    )
    parser.add_argument(
        "--plan",
        type=Path,
        default=root / "bench" / "full.tsv",
    )
    parser.add_argument(
        "--writer-targets",
        type=Path,
        default=root / "tools" / "writer-targets.tsv",
    )
    return parser.parse_args()


def read_fixture_manifest(path: Path) -> dict[str, Path]:
    fixtures: dict[str, Path] = {}
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    header_entry = next(
        (
            (line_number, line[2:])
            for line_number, line in enumerate(lines, 1)
            if line.startswith("# id\t")
        ),
        None,
    )
    if header_entry is None:
        raise ValueError(f"{path}: missing fixture manifest header")
    header_line, header = header_entry
    if not any(line.strip() == f"# {FIXTURE_SCHEMA}" for line in lines):
        raise ValueError(f"{path}: missing {FIXTURE_SCHEMA} marker")
    data_lines = [header] + [
        line for line in lines if line.strip() and not line.startswith("#")
    ]
    rows = csv.DictReader(data_lines, delimiter="\t")
    if rows.fieldnames != [
        "id",
        "path",
        "classification",
        "recommendation",
        "feature_checks",
        "description",
    ]:
        raise ValueError(f"{path}: unexpected fixture manifest columns")
    for line_number, row in enumerate(rows, header_line + 1):
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"{path}:{line_number}: wrong fixture field count")
        fixture_id = row["id"]
        if not fixture_id or fixture_id in fixtures:
            raise ValueError(f"{path}:{line_number}: duplicate or empty fixture ID")
        fixture_path = (path.parent / row["path"]).resolve()
        try:
            fixture_path.relative_to(path.parent.resolve())
        except ValueError as error:
            raise ValueError(
                f"{path}:{line_number}: fixture path escapes root"
            ) from error
        if not fixture_path.is_file():
            raise ValueError(f"{path}:{line_number}: missing {fixture_path}")
        fixtures[fixture_id] = fixture_path
    if not fixtures:
        raise ValueError(f"{path}: empty fixture manifest")
    return fixtures


def validate_size_plan(value: str, label: str) -> None:
    if value in {"-", "depth:limit-1,limit,limit+1", "bytes:limit-1,limit,limit+1"}:
        return
    count_prefix = next(
        (
            prefix
            for prefix in ("depth:", "attributes:", "documents:")
            if value.startswith(prefix)
        ),
        None,
    )
    if count_prefix is not None:
        values = value.removeprefix(count_prefix).split(",")
        if (
            not values
            or any(not item.isdigit() or int(item) <= 0 for item in values)
            or len(values) != len(set(values))
        ):
            raise ValueError(f"{label}: invalid count plan")
        return
    elif value.startswith("bytes:"):
        values = value.removeprefix("bytes:").split(",")
    else:
        values = value.split(",")
    if not values or any(not item for item in values):
        raise ValueError(f"{label}: empty size plan")
    if len(values) != len(set(values)):
        raise ValueError(f"{label}: repeated size")
    for item in values:
        suffix = item[-1:]
        if suffix not in {"k", "m", "g"}:
            raise ValueError(f"{label}: size {item!r} has no binary suffix")
        number = item[:-1]
        if not number.isdigit() or int(number) <= 0:
            raise ValueError(f"{label}: invalid size {item!r}")
        multiplier = {"k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024}[suffix]
        if int(number) * multiplier > MAX_BENCHMARK_BYTES:
            raise ValueError(f"{label}: size {item!r} exceeds 1 GiB")


def read_oracles(path: Path) -> dict[str, dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    header_entry = next(
        (
            (line_number, line[2:])
            for line_number, line in enumerate(lines, 1)
            if line.startswith("# id\t")
        ),
        None,
    )
    if header_entry is None:
        raise ValueError(f"{path}: missing oracle manifest header")
    header_line, header = header_entry
    if sum(line.strip() == f"# {ORACLE_SCHEMA}" for line in lines) != 1:
        raise ValueError(f"{path}: expected one {ORACLE_SCHEMA} marker")
    rows = csv.DictReader(
        [header]
        + [line for line in lines if line.strip() and not line.startswith("#")],
        delimiter="\t",
    )
    if rows.fieldnames != ORACLE_COLUMNS:
        raise ValueError(f"{path}: unexpected oracle manifest columns")
    oracles: dict[str, dict[str, str]] = {}
    for line_number, row in enumerate(rows, header_line + 1):
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"{path}:{line_number}: wrong oracle field count")
        oracle_id = row["id"]
        if not oracle_id or oracle_id in oracles:
            raise ValueError(f"{path}:{line_number}: duplicate or empty oracle ID")
        if row["lane"] not in VALID_LANES:
            raise ValueError(f"{path}:{line_number}: unsupported oracle lane")
        if row["format"] not in VALID_ORACLE_FORMATS:
            raise ValueError(f"{path}:{line_number}: unsupported oracle format")
        fields = row["fields"].split(",")
        if (
            not fields
            or any(not field for field in fields)
            or len(fields) != len(set(fields))
        ):
            raise ValueError(f"{path}:{line_number}: invalid oracle fields")
        if row["status"] not in VALID_STATUSES:
            raise ValueError(f"{path}:{line_number}: unsupported oracle status")
        if not row["notes"]:
            raise ValueError(f"{path}:{line_number}: missing oracle reason")
        oracles[oracle_id] = row
    if not oracles:
        raise ValueError(f"{path}: empty oracle manifest")
    return oracles


def read_plan(path: Path) -> dict[str, list[int]]:
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    if sum(line.strip() == f"# {PLAN_SCHEMA}" for line in lines) != 1:
        raise ValueError(f"{path}: expected one {PLAN_SCHEMA} marker")
    data_lines = [line for line in lines if line.strip() and not line.startswith("#")]
    header_line = next(
        (
            line_number
            for line_number, line in enumerate(lines, 1)
            if line.strip() and not line.startswith("#")
        ),
        None,
    )
    if header_line is None:
        raise ValueError(f"{path}: missing benchmark plan header")
    rows = csv.DictReader(data_lines, delimiter="\t")
    if rows.fieldnames != ["shape", "sizes_mib", "rejection_fractions"]:
        raise ValueError(f"{path}: unexpected benchmark plan columns")
    shapes: dict[str, list[int]] = {}
    for line_number, row in enumerate(rows, header_line + 1):
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"{path}:{line_number}: wrong plan field count")
        shape = row["shape"]
        if not shape or shape in shapes:
            raise ValueError(f"{path}:{line_number}: duplicate or empty shape")
        sizes = row["sizes_mib"].split(",")
        if (
            not sizes
            or any(
                not value.isdigit() or not 1 <= int(value) <= 1024 for value in sizes
            )
            or len(sizes) != len(set(sizes))
        ):
            raise ValueError(f"{path}:{line_number}: invalid MiB sizes")
        shapes[shape] = [int(value) for value in sizes]
        fractions = row["rejection_fractions"]
        if shape == "rejection":
            values = fractions.split(",")
            if (
                not values
                or any(
                    not value.isdigit() or not 1 <= int(value) <= 99 for value in values
                )
                or len(values) != len(set(values))
            ):
                raise ValueError(f"{path}:{line_number}: invalid rejection fractions")
        elif fractions != "-":
            raise ValueError(f"{path}:{line_number}: fractions require rejection")
    if not shapes:
        raise ValueError(f"{path}: empty benchmark plan")
    return shapes


def read_writer_targets(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    if sum(line.strip() == f"# {WRITER_TARGET_SCHEMA}" for line in lines) != 1:
        raise ValueError(f"{path}: expected one {WRITER_TARGET_SCHEMA} marker")
    header_entry = next(
        (
            (line_number, line[2:])
            for line_number, line in enumerate(lines, 1)
            if line.startswith("# name\t")
        ),
        None,
    )
    if header_entry is None:
        raise ValueError(f"{path}: missing writer target header")
    header_line, header = header_entry
    reader = csv.DictReader(
        [header]
        + [line for line in lines if line.strip() and not line.startswith("#")],
        delimiter="\t",
    )
    if reader.fieldnames != WRITER_TARGET_COLUMNS:
        raise ValueError(f"{path}: unexpected writer target columns")
    targets: list[dict[str, str]] = []
    for line_number, row in enumerate(reader, header_line + 1):
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"{path}:{line_number}: wrong writer target field count")
        features = row["features"].split(",")
        if (
            row["name"] != "z-xml-writer"
            or row["executable"] != "z-xml-writer"
            or row["processor_class"] != "writer"
            or row["work_lane"] != "writer"
            or row["input_model"] != "manifest-selected"
            or set(features) != REQUIRED_WRITER_FEATURES
            or len(features) != len(set(features))
        ):
            raise ValueError(f"{path}:{line_number}: invalid writer target")
        targets.append(row)
    if len(targets) != 1:
        raise ValueError(f"{path}: expected one writer target")
    return targets


def validate(
    matrix: Path,
    fixtures_path: Path,
    oracles_path: Path,
    plan_path: Path,
    writer_targets_path: Path,
) -> int:
    fixtures = read_fixture_manifest(fixtures_path)
    oracles = read_oracles(oracles_path)
    plan_shapes = read_plan(plan_path)
    writer_targets = read_writer_targets(writer_targets_path)
    errors: list[str] = []
    rows: list[dict[str, str]] = []
    with matrix.open(encoding="utf-8", newline="") as stream:
        comments: list[str] = []
        data_lines: list[str] = []
        header_line = 0
        for line_number, line in enumerate(stream, 1):
            if line.startswith("#"):
                comments.append(line[1:].strip())
            elif line.strip():
                if not data_lines:
                    header_line = line_number
                data_lines.append(line)
    if comments.count(SCHEMA) != 1:
        errors.append(f"{matrix}: expected one {SCHEMA} marker")
    rows_reader = csv.DictReader(data_lines, delimiter="\t")
    if rows_reader.fieldnames != EXPECTED_COLUMNS:
        errors.append(f"{matrix}: unexpected matrix columns")
        return report(matrix, errors)
    for line_number, row in enumerate(rows_reader, header_line + 1):
        if None in row or any(value is None for value in row.values()):
            errors.append(f"{matrix}:{line_number}: wrong matrix field count")
            continue
        rows.append(row)
        label = f"{matrix}:{line_number}:{row.get('id', '<missing>')}"
        if not row["id"]:
            errors.append(f"{label}: empty ID")
        for field in ("family", "profile", "generator", "notes"):
            if not row[field]:
                errors.append(f"{label}: empty {field}")
        if row["lane"] not in VALID_LANES:
            errors.append(f"{label}: unsupported lane {row['lane']!r}")
        if row["expected"] not in VALID_EXPECTATIONS:
            errors.append(f"{label}: unsupported expectation {row['expected']!r}")
        if row["status"] not in VALID_STATUSES:
            errors.append(f"{label}: unsupported status {row['status']!r}")
        if row["oracle"] not in oracles:
            errors.append(f"{label}: unknown oracle {row['oracle']!r}")
        else:
            oracle = oracles[row["oracle"]]
            if not set(row["lane"].split(",")).issubset(oracle["lane"].split(",")):
                errors.append(f"{label}: oracle does not cover the shape lane")
            if row["status"] == "ready" and oracle["status"] != "ready":
                errors.append(
                    f"{label}: ready row uses an unready oracle {row['oracle']!r}"
                )
        input_models = row["input_models"].split(",")
        allowed_models = (
            WRITER_INPUT_MODELS if row["lane"] == "writer" else READER_INPUT_MODELS
        )
        if (
            not input_models
            or any(model not in allowed_models for model in input_models)
            or len(input_models) != len(set(input_models))
        ):
            errors.append(f"{label}: invalid input models")
        if row["lane"] == "writer":
            contract = WRITER_SHAPES.get(row["id"])
            if contract is None:
                errors.append(f"{label}: unsupported Writer shape")
            else:
                expected_oracle, expected_models = contract
                expected_fields = {
                    "profile": "writer-xml10-namespaces",
                    "seed_fixture": "-",
                    "generator": row["id"],
                    "expected": "emit",
                    "oracle": expected_oracle,
                    "status": "ready",
                }
                for field, expected in expected_fields.items():
                    if row[field] != expected:
                        errors.append(f"{label}: Writer {field} must be {expected!r}")
                if set(input_models) != expected_models:
                    errors.append(f"{label}: Writer input models do not match")
        if (row["lane"] == "writer") != (row["expected"] == "emit"):
            errors.append(f"{label}: writer lane and emit expectation disagree")
        if row["generator"] in {"-", "planned"}:
            errors.append(f"{label}: missing generator or fixed-input owner")
        if row["status"] == "ready" and row["generator"] not in READY_GENERATORS:
            errors.append(f"{label}: ready generator is not available")
        try:
            validate_size_plan(row["size_plan"], label)
        except ValueError as error:
            errors.append(str(error))
        seed = row["seed_fixture"]
        if seed != "-":
            if seed not in fixtures:
                errors.append(f"{label}: unknown seed fixture {seed!r}")
        elif row["status"] == "ready" and row["generator"] == "seed-only":
            errors.append(f"{label}: seed-only ready row has no seed fixture")
        if row["expected"] == "reject" and row["oracle"] == "common-summary-v1":
            errors.append(f"{label}: rejection cannot use common-summary-v1")
        if (
            row["expected"] == "resource-limit"
            and row["oracle"] != "limit-diagnostic-v1"
        ):
            errors.append(f"{label}: resource-limit needs limit-diagnostic-v1")
    ids = [row["id"] for row in rows]
    for duplicate in sorted({item for item in ids if ids.count(item) > 1}):
        errors.append(f"{matrix}: duplicate shape ID {duplicate}")
    writer_ids = {row["id"] for row in rows if row["lane"] == "writer"}
    missing_writer_ids = set(WRITER_SHAPES).difference(writer_ids)
    if missing_writer_ids:
        errors.append(
            f"{matrix}: missing Writer shapes: " + ",".join(sorted(missing_writer_ids))
        )
    ready_event_sizes: dict[str, set[str]] = {}
    for row in rows:
        if row["status"] == "ready" and row["lane"] == "event":
            ready_event_sizes.setdefault(row["generator"], set()).update(
                row["size_plan"].split(",")
            )
    missing_plan_owners = set(plan_shapes).difference(ready_event_sizes)
    if missing_plan_owners:
        errors.append(
            f"{plan_path}: shapes without ready event owners: "
            + ",".join(sorted(missing_plan_owners))
        )
    for shape, sizes_mib in plan_shapes.items():
        declared_sizes = ready_event_sizes.get(shape, set())
        missing_sizes = []
        for size_mib in sizes_mib:
            labels = {f"{size_mib}m"}
            if size_mib % 1024 == 0:
                labels.add(f"{size_mib // 1024}g")
            if declared_sizes.isdisjoint(labels):
                missing_sizes.append(str(size_mib))
        if missing_sizes:
            errors.append(
                f"{plan_path}: {shape} MiB sizes absent from the shape matrix: "
                + ",".join(missing_sizes)
            )
    return report(
        matrix,
        errors,
        len(rows),
        len(oracles),
        len(plan_shapes),
        len(writer_targets),
    )


def report(
    matrix: Path,
    errors: list[str],
    rows: int = 0,
    oracles: int = 0,
    plan_shapes: int = 0,
    writer_targets: int = 0,
) -> int:
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(
        f"validated {rows} shape rows, {oracles} oracles, "
        f"{plan_shapes} full-plan shapes, and {writer_targets} Writer target "
        f"in {matrix}"
    )
    return 0


def main() -> int:
    args = parse_args()
    try:
        return validate(
            args.matrix.resolve(),
            args.fixtures.resolve(),
            args.oracles.resolve(),
            args.plan.resolve(),
            args.writer_targets.resolve(),
        )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
