"""Build and verify complete generated corpus directories.

Corpus generators build a temporary tree under ``data/generated``. Check mode
compares the complete file set and file bytes without changing the selected
tree. Generation publishes the completed tree only after the build succeeds.
"""

from __future__ import annotations

import shutil
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import BinaryIO


def _generated_root() -> Path:
    return Path(__file__).resolve().parents[2] / "data" / "generated"


def default_output(schema: str) -> Path:
    return _generated_root() / schema


def write_repeated(stream: BinaryIO, record: bytes, count: int) -> None:
    per_block = max(1, (1024 * 1024) // len(record))
    block = record * per_block
    while count >= per_block:
        stream.write(block)
        count -= per_block
    if count:
        stream.write(record * count)


def write_file(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _files_equal(left: Path, right: Path) -> bool:
    if left.stat().st_size != right.stat().st_size:
        return False
    with left.open("rb") as left_stream, right.open("rb") as right_stream:
        while True:
            left_bytes = left_stream.read(1024 * 1024)
            right_bytes = right_stream.read(1024 * 1024)
            if left_bytes != right_bytes:
                return False
            if not left_bytes:
                return True


def _compare(expected: Path, actual: Path) -> list[str]:
    errors: list[str] = []
    expected_files = {
        path.relative_to(expected) for path in expected.rglob("*") if path.is_file()
    }
    actual_files = {
        path.relative_to(actual) for path in actual.rglob("*") if path.is_file()
    }
    for path in sorted(expected_files - actual_files):
        errors.append(f"missing generated file: {path}")
    for path in sorted(actual_files - expected_files):
        errors.append(f"unexpected generated file: {path}")
    for path in sorted(expected_files & actual_files):
        if not _files_equal(expected / path, actual / path):
            errors.append(f"generated file differs: {path}")
    return errors


def generate_or_check(
    output_argument: Path,
    *,
    check: bool,
    temporary_prefix: str,
    label: str,
    build: Callable[[Path], None],
) -> int:
    output = output_argument.resolve()
    generated_root = _generated_root().resolve()
    if (
        output_argument.is_symlink()
        or output == generated_root
        or not output.is_relative_to(generated_root)
        or (output.exists() and not output.is_dir())
    ):
        raise ValueError("output directory must be a directory under data/generated")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=temporary_prefix, dir=output.parent
    ) as name:
        temporary = Path(name)
        build(temporary)
        if check:
            if not output.is_dir():
                raise ValueError(f"missing generated corpus: {output}")
            errors = _compare(temporary, output)
            if errors:
                raise ValueError("\n".join(errors))
            print(f"verified {label} at {output}")
            return 0
        if output.exists():
            shutil.rmtree(output)
        temporary.replace(output)
    print(f"generated {label} at {output}")
    return 0
