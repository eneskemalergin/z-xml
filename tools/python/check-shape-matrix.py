#!/usr/bin/env python3
"""Validate the local XML shape matrix and its fixture references."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

SCHEMA = "z-xml-shape-matrix-v1"
FIXTURE_SCHEMA = "z-xml-fixtures-v2"
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
    return parser.parse_args()


def read_fixture_manifest(path: Path) -> dict[str, Path]:
    fixtures: dict[str, Path] = {}
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    header = next(
        (line[2:] for line in lines if line.startswith("# id\t")),
        None,
    )
    if header is None:
        raise ValueError(f"{path}: missing fixture manifest header")
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
    for line_number, row in enumerate(rows, 2):
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
        if not values or any(not item.isdigit() or int(item) <= 0 for item in values):
            raise ValueError(f"{label}: invalid count plan")
        return
    elif value.startswith("bytes:"):
        values = value.removeprefix("bytes:").split(",")
    else:
        values = value.split(",")
    if not values or any(not item for item in values):
        raise ValueError(f"{label}: empty size plan")
    for item in values:
        if item.endswith(("k", "m", "g")):
            number = item[:-1]
        else:
            raise ValueError(f"{label}: size {item!r} has no binary suffix")
        if not number.isdigit() or int(number) <= 0:
            raise ValueError(f"{label}: invalid size {item!r}")


def read_oracles(path: Path) -> dict[str, str]:
    with path.open(encoding="utf-8", newline="") as stream:
        lines = list(stream)
    header = next(
        (line[2:] for line in lines if line.startswith("# id\t")),
        None,
    )
    if header is None:
        raise ValueError(f"{path}: missing oracle manifest header")
    rows = csv.DictReader(
        [header]
        + [line for line in lines if line.strip() and not line.startswith("#")],
        delimiter="\t",
    )
    if rows.fieldnames != ORACLE_COLUMNS:
        raise ValueError(f"{path}: unexpected oracle manifest columns")
    oracles: dict[str, str] = {}
    for line_number, row in enumerate(rows, 2):
        oracle_id = row["id"]
        if not oracle_id or oracle_id in oracles:
            raise ValueError(f"{path}:{line_number}: duplicate or empty oracle ID")
        if row["status"] not in VALID_STATUSES:
            raise ValueError(f"{path}:{line_number}: unsupported oracle status")
        oracles[oracle_id] = row["status"]
    if not oracles:
        raise ValueError(f"{path}: empty oracle manifest")
    return oracles


def validate(matrix: Path, fixtures_path: Path, oracles_path: Path) -> int:
    fixtures = read_fixture_manifest(fixtures_path)
    oracles = read_oracles(oracles_path)
    errors: list[str] = []
    rows: list[dict[str, str]] = []
    with matrix.open(encoding="utf-8", newline="") as stream:
        comments: set[str] = set()
        data_lines: list[str] = []
        for line in stream:
            if line.startswith("#"):
                comments.add(line[1:].strip())
            elif line.strip():
                data_lines.append(line)
    if SCHEMA not in comments:
        errors.append(f"{matrix}: missing {SCHEMA} marker")
    rows_reader = csv.DictReader(data_lines, delimiter="\t")
    if rows_reader.fieldnames != EXPECTED_COLUMNS:
        errors.append(f"{matrix}: unexpected matrix columns")
        return report(matrix, errors)
    for line_number, row in enumerate(rows_reader, 2):
        rows.append(row)
        label = f"{matrix}:{line_number}:{row.get('id', '<missing>')}"
        if not row["id"]:
            errors.append(f"{label}: empty ID")
        if row["lane"] not in VALID_LANES:
            errors.append(f"{label}: unsupported lane {row['lane']!r}")
        if row["expected"] not in VALID_EXPECTATIONS:
            errors.append(f"{label}: unsupported expectation {row['expected']!r}")
        if row["status"] not in VALID_STATUSES:
            errors.append(f"{label}: unsupported status {row['status']!r}")
        if row["oracle"] not in oracles:
            errors.append(f"{label}: unknown oracle {row['oracle']!r}")
        elif row["status"] == "ready" and oracles[row["oracle"]] != "ready":
            errors.append(
                f"{label}: ready row uses an unready oracle {row['oracle']!r}"
            )
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
    return report(matrix, errors, len(rows))


def report(matrix: Path, errors: list[str], rows: int = 0) -> int:
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"validated {rows} shape rows and their seed references in {matrix}")
    return 0


def main() -> int:
    args = parse_args()
    try:
        return validate(
            args.matrix.resolve(), args.fixtures.resolve(), args.oracles.resolve()
        )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
