#!/usr/bin/env python3
"""Generate the repeated Document schedule from existing generated XML corpora."""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import tempfile
from pathlib import Path

SCHEMA = "z-xml-document-repeat-v1"
SOURCE_SCHEMA = "z-xml-generated-v3"
SIZE_CEILING = 1024 * 1024 * 1024
FIELDS = (
    "id",
    "path",
    "actual_bytes",
    "classification",
    "resource_paths",
    "targets",
    "program_args",
    "expected_result",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def read_source(manifest: Path, workload_id: str) -> tuple[Path, dict[str, object]]:
    lines = manifest.read_text(encoding="utf-8").splitlines()
    comments = {line[1:].strip() for line in lines if line.startswith("#")}
    if (
        SOURCE_SCHEMA not in comments
        or f"size ceiling: {SIZE_CEILING} bytes" not in comments
    ):
        raise ValueError(f"{manifest}: unsupported source schema")
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    required = {
        "id",
        "path",
        "target_bytes",
        "actual_bytes",
        "classification",
        "expected_summary",
    }
    if rows.fieldnames is None or required.difference(rows.fieldnames):
        raise ValueError(f"{manifest}: incomplete source manifest")
    matches = [row for row in rows if row["id"] == workload_id]
    if len(matches) != 1:
        raise ValueError(f"{manifest}: expected one {workload_id} row")
    row = matches[0]
    source = (manifest.parent / row["path"]).resolve()
    root = manifest.parent.resolve()
    if not source.is_relative_to(root) or not source.is_file():
        raise ValueError(f"{manifest}: invalid {workload_id} source")
    actual_bytes = int(row["actual_bytes"])
    if (
        row["classification"] != "benchmark-valid"
        or actual_bytes <= 0
        or int(row["target_bytes"]) != actual_bytes
        or source.stat().st_size != actual_bytes
    ):
        raise ValueError(f"{manifest}: invalid {workload_id} source row")

    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"{manifest}: duplicate {workload_id} summary field")
            result[key] = value
        return result

    expected = json.loads(row["expected_summary"], object_pairs_hook=unique_object)
    required = {"elements", "attributes", "text_bytes", "checksum"}
    if not isinstance(expected, dict) or set(expected) != required:
        raise ValueError(f"{manifest}: invalid {workload_id} summary")
    if any(
        type(expected[field]) is not int or expected[field] < 0
        for field in required - {"checksum"}
    ):
        raise ValueError(f"{manifest}: invalid {workload_id} counts")
    checksum = expected["checksum"]
    if (
        not isinstance(checksum, str)
        or len(checksum) != 16
        or any(byte not in "0123456789abcdef" for byte in checksum)
    ):
        raise ValueError(f"{manifest}: invalid {workload_id} checksum")
    return source, expected


def render(root: Path) -> str:
    small, small_summary = read_source(
        root / "z-xml-generated-v3-persistent" / "manifest.tsv", "mixed-16k"
    )
    large, large_summary = read_source(
        root / "z-xml-generated-v3-document" / "manifest.tsv", "mixed-64m"
    )
    next_path = os.path.relpath(small, start=large.parent)
    schedules = (
        (
            "document-repeat-small",
            small,
            (),
            ("--repeat=4096",),
            small_summary,
            None,
        ),
        (
            "document-repeat-large",
            large,
            (),
            ("--repeat=8",),
            large_summary,
            None,
        ),
        (
            "document-repeat-large-small",
            large,
            (small,),
            ("--repeat=1", f"--next-file={next_path}", "--next-repeat=4096"),
            large_summary,
            small_summary,
        ),
    )

    output = io.StringIO(newline="")
    output.write(f"# {SCHEMA}\n")
    writer = csv.DictWriter(output, FIELDS, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for name, source, resources, arguments, primary, next_summary in schedules:
        writer.writerow(
            {
                "id": name,
                "path": source.relative_to(root),
                "actual_bytes": source.stat().st_size,
                "classification": "benchmark-valid",
                "resource_paths": (
                    ",".join(str(path.relative_to(root)) for path in resources)
                    if resources
                    else "-"
                ),
                "targets": "z-xml-document-repeat",
                "program_args": " ".join(arguments),
                "expected_result": json.dumps(
                    {"primary": primary, "next": next_summary},
                    separators=(",", ":"),
                    sort_keys=True,
                ),
            }
        )
    return output.getvalue()


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parents[2] / "data" / "generated"
    output = root / "z-xml-document-repeat-v1.tsv"
    expected = render(root)
    if args.check:
        if not output.is_file() or output.read_text(encoding="utf-8") != expected:
            print(f"{output}: differs from generated schedule")
            return 1
        print(f"verified {output}")
        return 0
    root.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=root, delete=False
        ) as stream:
            stream.write(expected)
            temporary = Path(stream.name)
        temporary.replace(output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"generated {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
