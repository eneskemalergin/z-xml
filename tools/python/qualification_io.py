"""Read qualification controls and publish complete qualification results.

Control files have a fixed size limit. JSON decoders reject duplicate fields
while preserving the established error text for their two existing protocols.
TSV publication replaces the result only after every row has been written.
"""

from __future__ import annotations

import csv
import json
import tempfile
from pathlib import Path

MAX_CONTROL_BYTES = 16 * 1024 * 1024


def read_limited(path: Path, limit: int = MAX_CONTROL_BYTES) -> bytes:
    if not path.is_file():
        raise ValueError(f"{path}: expected a regular file")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{path}: exceeds the {limit}-byte control limit")
    return data


def decode_json(value: str | bytes) -> object:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        decoded: dict[str, object] = {}
        for key, item in pairs:
            if key in decoded:
                raise ValueError(f"duplicate JSON field: {key}")
            decoded[key] = item
        return decoded

    return json.loads(value, object_pairs_hook=unique_object)


def decode_json_object(value: str) -> dict[str, object]:
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


def publish_tsv(
    path: Path, fieldnames: list[str], rows: list[dict[str, object]]
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="", dir=path.parent, delete=False
        ) as stream:
            temporary = Path(stream.name)
            writer = csv.DictWriter(
                stream, fieldnames, delimiter="\t", lineterminator="\n"
            )
            writer.writeheader()
            writer.writerows(rows)
        temporary.replace(path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
