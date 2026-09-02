#!/usr/bin/env python3
"""Generate deterministic XML performance workloads without holding them in memory."""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

FNV_OFFSET = 14695981039346656037
FNV_PRIME = 1099511628211
SCHEMA = "z-xml-generated-v3"
PLAN_SCHEMA = "z-xml-benchmark-plan-v1"
DOCUMENT_OVERHEAD = len(b"<root></root>")
MAX_TARGET_BYTES = 1024 * 1024 * 1024
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


def fnv_update(value: int, data: bytes) -> int:
    for byte in data:
        value ^= byte
        value = (value * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


@dataclass
class Stats:
    elements: int = 0
    attributes: int = 0
    text_bytes: int = 0
    checksum: int = FNV_OFFSET

    def start(
        self, name: bytes, attributes: tuple[tuple[bytes, bytes], ...] = ()
    ) -> None:
        self.elements += 1
        self.checksum = fnv_update(self.checksum, b"\x01" + name)
        for attr_name, attr_value in attributes:
            self.attributes += 1
            self.checksum = fnv_update(
                self.checksum, b"\x02" + attr_name + b"\x03" + attr_value
            )

    def text(self, value: bytes) -> None:
        self.text_bytes += len(value)
        self.checksum = fnv_update(self.checksum, value)

    def end(self, name: bytes) -> None:
        self.checksum = fnv_update(self.checksum, b"\x04" + name)

    def compact_json(self) -> str:
        return json.dumps(
            {
                "elements": self.elements,
                "attributes": self.attributes,
                "text_bytes": self.text_bytes,
                "checksum": f"{self.checksum:016x}",
            },
            separators=(",", ":"),
        )

    @classmethod
    def from_json(cls, value: object) -> Stats:
        if not isinstance(value, dict):
            raise TypeError("summary output is not a JSON object")
        expected = {"elements", "attributes", "text_bytes", "checksum"}
        if set(value) != expected:
            raise ValueError("summary output has unexpected fields")
        if (
            type(value["elements"]) is not int
            or type(value["attributes"]) is not int
            or type(value["text_bytes"]) is not int
            or not isinstance(value["checksum"], str)
            or len(value["checksum"]) != 16
        ):
            raise ValueError("summary output has invalid values")
        try:
            checksum = int(value["checksum"], 16)
        except ValueError as error:
            raise ValueError("summary output has invalid values") from error
        elements = value["elements"]
        attributes = value["attributes"]
        text_bytes = value["text_bytes"]
        if (
            min(checksum, elements, attributes, text_bytes) < 0
            or checksum > 0xFFFFFFFFFFFFFFFF
        ):
            raise ValueError("summary output values are out of range")
        return cls(elements, attributes, text_bytes, checksum)


class Output:
    def __init__(self, stream: BinaryIO):
        self.stream = stream
        self.size = 0

    def write(self, data: bytes) -> None:
        self.stream.write(data)
        self.size += len(data)

    def write_repeated(self, record: bytes, count: int) -> None:
        records_per_block = max(1, (1024 * 1024) // len(record))
        block = record * records_per_block
        while count >= records_per_block:
            self.write(block)
            count -= records_per_block
        if count:
            self.write(record * count)


class ComparingOutput(Output):
    def __init__(self, stream: BinaryIO):
        super().__init__(stream)
        self.matches = True

    def write(self, data: bytes) -> None:
        if self.stream.read(len(data)) != data:
            self.matches = False
        self.size += len(data)

    def finish(self) -> bool:
        return self.matches and self.stream.read(1) == b""


def begin_document(output: Output, stats: Stats | None) -> None:
    output.write(b"<root>")
    if stats is not None:
        stats.start(b"root")


def end_document(output: Output, stats: Stats | None) -> None:
    output.write(b"</root>")
    if stats is not None:
        stats.end(b"root")


def generate_text(output: Output, stats: Stats | None, target_bytes: int) -> None:
    begin_document(output, stats)
    remaining = target_bytes - DOCUMENT_OVERHEAD
    pattern = b"abcdefghijklmnopqrstuvwxyz0123456789\n"
    block = pattern * max(1, (1024 * 1024) // len(pattern))
    while remaining:
        chunk = block[:remaining] if remaining < len(block) else block
        output.write(chunk)
        if stats is not None:
            stats.text(chunk)
        remaining -= len(chunk)
    end_document(output, stats)


def generate_utf16_text(output: Output, stats: Stats | None, target_bytes: int) -> None:
    prefix = b"\xff\xfe" + "<root>".encode("utf-16-le")
    suffix = "</root>".encode("utf-16-le")
    text = "aéλ🙂\n"
    encoded = text.encode("utf-16-le")
    logical = text.encode()
    available = target_bytes - len(prefix) - len(suffix)
    count, remainder = divmod(available, len(encoded))
    if available < 0 or remainder % 2 != 0:
        raise ValueError("utf16-text target cannot preserve complete UTF-16 units")
    filler = remainder // 2
    output.write(prefix)
    if stats is not None:
        stats.start(b"root")
    output.write_repeated(encoded, count)
    if filler:
        output.write(b"x\x00" * filler)
    if stats is not None:
        records_per_block = max(1, (1024 * 1024) // len(logical))
        block = logical * records_per_block
        while count >= records_per_block:
            stats.text(block)
            count -= records_per_block
        if count:
            stats.text(logical * count)
        if filler:
            stats.text(b"x" * filler)
    output.write(suffix)
    if stats is not None:
        stats.end(b"root")


def generate_repeated(
    output: Output,
    stats: Stats | None,
    target_bytes: int,
    raw_record: bytes,
    event: Callable[[Stats], None],
) -> None:
    begin_document(output, stats)
    payload_bytes = target_bytes - DOCUMENT_OVERHEAD
    record_count, filler_bytes = divmod(payload_bytes, len(raw_record))
    output.write_repeated(raw_record, record_count)
    if stats is not None:
        for _ in range(record_count):
            event(stats)
    if filler_bytes:
        filler = b"x" * filler_bytes
        output.write(filler)
        if stats is not None:
            stats.text(filler)
    end_document(output, stats)


def generate_sequence(
    output: Output,
    stats: Stats | None,
    target_bytes: int,
    records: tuple[tuple[bytes, Callable[[Stats], None]], ...],
) -> None:
    begin_document(output, stats)
    remaining = target_bytes - DOCUMENT_OVERHEAD
    index = 0
    while remaining:
        raw_record, event = records[index % len(records)]
        if len(raw_record) > remaining:
            filler = b"x" * remaining
            output.write(filler)
            if stats is not None:
                stats.text(filler)
            break
        output.write(raw_record)
        if stats is not None:
            event(stats)
        remaining -= len(raw_record)
        index += 1
    end_document(output, stats)


def empty_event(stats: Stats) -> None:
    stats.start(b"n")
    stats.end(b"n")


def wide_event(stats: Stats) -> None:
    stats.start(b"item", ((b"id", b"0000000000"),))
    stats.text(b"x")
    stats.end(b"item")


ATTRIBUTE_SET = tuple(
    (f"a{index:02d}".encode(), b"0123456789abcdef") for index in range(16)
)
ATTRIBUTE_RECORD = (
    b"<item "
    + b" ".join(name + b'="' + value + b'"' for name, value in ATTRIBUTE_SET)
    + b"/>"
)


def attribute_event(stats: Stats) -> None:
    stats.start(b"item", ATTRIBUTE_SET)
    stats.end(b"item")


def mixed_event(stats: Stats) -> None:
    stats.text(b"a")
    stats.start(b"item", ((b"id", b"0000000000"),))
    stats.text(b"x<y>")
    stats.end(b"item")


def escaped_event(stats: Stats) -> None:
    stats.text("&\u03bb<>\"'".encode())


def unicode_event(stats: Stats) -> None:
    stats.text("a\u00e9\u03bb\U0001f642".encode())


VALIDATION_MODEL_PREFIX = (
    b"<!DOCTYPE root [<!ELEMENT root (item*)><!ELEMENT item (left,right?)>"
    b"<!ELEMENT left (#PCDATA)><!ELEMENT right (#PCDATA)>]><root>"
)
VALIDATION_MODEL_RECORD = b"<item><left>x</left><right>y</right></item>"
VALIDATION_ID_PREFIX = (
    b"<!DOCTYPE root [<!ELEMENT root (item*)><!ELEMENT item EMPTY>"
    b"<!ATTLIST item id ID #REQUIRED ref IDREF #IMPLIED>]><root>"
)


def validation_model_event(stats: Stats) -> None:
    stats.start(b"item")
    stats.start(b"left")
    stats.text(b"x")
    stats.end(b"left")
    stats.start(b"right")
    stats.text(b"y")
    stats.end(b"right")
    stats.end(b"item")


def generate_validation_models(
    output: Output, stats: Stats | None, target_bytes: int
) -> None:
    suffix = b"</root>"
    available = target_bytes - len(VALIDATION_MODEL_PREFIX) - len(suffix)
    if available < 0:
        raise ValueError("validation-model target is smaller than its declarations")
    output.write(VALIDATION_MODEL_PREFIX)
    if stats is not None:
        stats.start(b"root")
    count, filler = divmod(available, len(VALIDATION_MODEL_RECORD))
    output.write_repeated(VALIDATION_MODEL_RECORD, count)
    if stats is not None:
        for _ in range(count):
            validation_model_event(stats)
    if filler:
        output.write(b" " * filler)
        if stats is not None:
            stats.text(b" " * filler)
    output.write(suffix)
    if stats is not None:
        stats.end(b"root")


def generate_validation_identifiers(
    output: Output, stats: Stats | None, target_bytes: int
) -> None:
    suffix = b"</root>"
    sample = b'<item id="i0000000000" ref="i0000000000"/>'
    available = target_bytes - len(VALIDATION_ID_PREFIX) - len(suffix)
    if available < 0:
        raise ValueError(
            "validation-identifier target is smaller than its declarations"
        )
    count, filler = divmod(available, len(sample))
    output.write(VALIDATION_ID_PREFIX)
    if stats is not None:
        stats.start(b"root")
    for index in range(count):
        value = f"i{index:010d}".encode()
        record = b'<item id="' + value + b'" ref="' + value + b'"/>'
        output.write(record)
        if stats is not None:
            stats.start(b"item", ((b"id", value), (b"ref", value)))
            stats.end(b"item")
    if filler:
        output.write(b" " * filler)
        if stats is not None:
            stats.text(b" " * filler)
    output.write(suffix)
    if stats is not None:
        stats.end(b"root")


def record_short_event(stats: Stats) -> None:
    stats.start(b"entry", ((b"id", b"a"), (b"kind", b"short")))
    stats.text(b"alpha")
    stats.end(b"entry")


def record_mixed_event(stats: Stats) -> None:
    stats.start(b"entry", ((b"id", b"medium-id"), (b"kind", b"mixed")))
    stats.start(b"title")
    stats.text("Title & \u03bb".encode())
    stats.end(b"title")
    stats.start(b"meta", ((b"key", b"one"), (b"value", b"1")))
    stats.end(b"meta")
    stats.start(b"meta", ((b"key", b"two"), (b"value", b"2")))
    stats.end(b"meta")
    stats.text(b"tail <raw>")
    stats.end(b"entry")


def record_unicode_event(stats: Stats) -> None:
    stats.start(b"entry", ((b"id", b"longer-id-0003"), (b"kind", b"unicode")))
    stats.text("\u00e9 \u03bb \U0001f642".encode())
    stats.end(b"entry")


RECORDS = (
    (b'<entry id="a" kind="short">alpha</entry>', record_short_event),
    (
        (
            b"<entry id='medium-id' kind='mixed'><title>Title &amp; &#x3bb;</title>"
            b"<meta key=\"one\" value=\"1\"/><meta key='two' value='2'/>"
            b"<![CDATA[tail <raw>]]></entry>"
        ),
        record_mixed_event,
    ),
    (
        '<entry id="longer-id-0003" kind="unicode">\u00e9 \u03bb \U0001f642</entry>'.encode(),
        record_unicode_event,
    ),
)


def varied_attribute_record(count: int, quote: bytes) -> bytes:
    attributes = []
    for index in range(count):
        name = f"a{index:02d}".encode()
        value = f"value-{index:02d}".encode()
        attributes.append(name + b"=" + quote + value + quote)
    return b"<item " + b" ".join(attributes) + b"/>"


def varied_attribute_event(count: int, stats: Stats) -> None:
    attributes = tuple(
        (f"a{index:02d}".encode(), f"value-{index:02d}".encode())
        for index in range(count)
    )
    stats.start(b"item", attributes)
    stats.end(b"item")


VARIED_ATTRIBUTES = tuple(
    (
        varied_attribute_record(count, b'"' if index % 2 == 0 else b"'"),
        lambda stats, selected=count: varied_attribute_event(selected, stats),
    )
    for index, count in enumerate((1, 4, 8, 16, 24))
)


SHAPES: dict[str, tuple[bytes, Callable[[Stats], None]] | None] = {
    "text": None,
    "markup": (b"<n/>", empty_event),
    "wide": (b'<item id="0000000000">x</item>', wide_event),
    "attributes": (ATTRIBUTE_RECORD, attribute_event),
    "records": None,
    "attributes-varied": None,
    "mixed": (
        b'a<item id="0000000000"><![CDATA[x<y>]]></item><!--c--><?p v?>',
        mixed_event,
    ),
    "escaped": (b"&amp;&#x3bb;&lt;&gt;&quot;&apos;", escaped_event),
    "unicode": ("a\u00e9\u03bb\U0001f642".encode(), unicode_event),
    "utf16-text": None,
    "validation-models": None,
    "validation-identifiers": None,
}

SHAPE_FEATURES = {
    "text": "document",
    "markup": "document,element_matching",
    "wide": "document,attributes,element_matching",
    "attributes": "document,attributes",
    "records": "document,attributes,element_matching,cdata,predefined_entities,numeric_references,utf8",
    "attributes-varied": "document,attributes",
    "mixed": "document,attributes,element_matching,cdata,comments,pi",
    "escaped": "document,predefined_entities,numeric_references",
    "unicode": "document,utf8",
    "utf16-text": "document,utf16",
    "validation-models": "document,dtd",
    "validation-identifiers": "document,dtd",
}


def generate_shape(
    output: Output, stats: Stats | None, shape: str, target_bytes: int
) -> None:
    if shape == "utf16-text":
        generate_utf16_text(output, stats, target_bytes)
        return
    if shape == "records":
        generate_sequence(output, stats, target_bytes, RECORDS)
        return
    if shape == "attributes-varied":
        generate_sequence(output, stats, target_bytes, VARIED_ATTRIBUTES)
        return
    if shape == "validation-models":
        generate_validation_models(output, stats, target_bytes)
        return
    if shape == "validation-identifiers":
        generate_validation_identifiers(output, stats, target_bytes)
        return
    definition = SHAPES[shape]
    if definition is None:
        generate_text(output, stats, target_bytes)
        return
    raw_record, event = definition
    generate_repeated(output, stats, target_bytes, raw_record, event)


def generate_deep(output: Output, stats: Stats, depth: int) -> None:
    for _ in range(depth):
        output.write(b"<n>")
        stats.start(b"n")
    output.write(b"x")
    stats.text(b"x")
    for _ in range(depth):
        output.write(b"</n>")
        stats.end(b"n")


def rejection_offset(target_bytes: int, fraction: int) -> int:
    valid_record = b"<n>x</n>"
    bad_record = b"<n>x</bad>"
    payload_bytes = target_bytes - DOCUMENT_OVERHEAD
    if payload_bytes < len(bad_record):
        raise ValueError("rejection target is too small")
    count = 1 + (payload_bytes - len(bad_record)) // len(valid_record)
    bad_index = min(count - 1, max(0, round((count - 1) * fraction / 100)))
    return len(b"<root>") + bad_index * len(valid_record) + len(b"<n>x")


def generate_rejection(output: Output, target_bytes: int, fraction: int) -> int:
    valid_record = b"<n>x</n>"
    bad_record = b"<n>x</bad>"
    payload_bytes = target_bytes - DOCUMENT_OVERHEAD
    if payload_bytes < len(bad_record):
        raise ValueError("rejection target is too small")
    count = 1 + (payload_bytes - len(bad_record)) // len(valid_record)
    filler_bytes = payload_bytes - len(bad_record) - (count - 1) * len(valid_record)
    bad_index = min(count - 1, max(0, round((count - 1) * fraction / 100)))
    fatal_offset = rejection_offset(target_bytes, fraction)
    output.write(b"<root>")
    output.write_repeated(valid_record, bad_index)
    output.write(bad_record)
    output.write_repeated(valid_record, count - bad_index - 1)
    if filler_bytes:
        output.write(b"x" * filler_bytes)
    output.write(b"</root>")
    return fatal_offset


def generated_bytes_match(path: Path, row: dict[str, str]) -> bool:
    with path.open("rb") as stream:
        output = ComparingOutput(stream)
        if row["shape"] == "rejection":
            generate_rejection(
                output,
                int(row["target_bytes"]),
                int(row["rejection_fraction"]),
            )
        elif row["shape"] == "deep":
            depth = int(row["id"].removeprefix("deep-"))
            generate_deep(output, Stats(), depth)
        else:
            generate_shape(output, None, row["shape"], int(row["target_bytes"]))
        return output.finish()


def atomic_generate(
    path: Path, generator: Callable[[Output], Stats | None]
) -> tuple[int, Stats | None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    try:
        with temporary.open("wb") as stream:
            output = Output(stream)
            stats = generator(output)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return output.size, stats


def collect_summary(program: Path, path: Path) -> Stats:
    completed = subprocess.run(
        [program, path],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=600,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise ValueError(f"summary program rejected {path}: {detail}")
    try:
        value = json.loads(completed.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"summary program returned invalid JSON for {path}") from error
    return Stats.from_json(value)


def parse_positive_csv(value: str, label: str) -> list[int]:
    items = value.split(",")
    if any(not item for item in items):
        raise argparse.ArgumentTypeError(f"{label} values must not be empty")
    try:
        values = [int(item) for item in items]
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            f"{label} must be comma-separated integers"
        ) from error
    if not values or any(item <= 0 for item in values):
        raise argparse.ArgumentTypeError(f"{label} values must be positive")
    if len(values) != len(set(values)):
        raise argparse.ArgumentTypeError(f"{label} values must not repeat")
    return sorted(values)


def validate_sizes_mib(values: list[int], label: str) -> None:
    if any(value * 1024 * 1024 > MAX_TARGET_BYTES for value in values):
        raise ValueError(f"{label} exceeds the 1 GiB corpus ceiling")


def validate_sizes_kib(values: list[int], label: str) -> None:
    if any(value * 1024 > MAX_TARGET_BYTES for value in values):
        raise ValueError(f"{label} exceeds the 1 GiB corpus ceiling")


def read_plan(path: Path) -> tuple[dict[str, list[int]], dict[int, list[int]]]:
    shape_sizes: dict[str, list[int]] = {}
    rejection_sizes: dict[int, list[int]] = {}
    with path.open(encoding="utf-8", newline="") as stream:
        comments: list[str] = []
        data_entries: list[tuple[int, str]] = []
        for line_number, line in enumerate(stream, 1):
            if line.startswith("#"):
                comments.append(line[1:].strip())
            elif line.strip():
                data_entries.append((line_number, line))
    if comments.count(PLAN_SCHEMA) != 1:
        raise ValueError(f"{path}: expected one {PLAN_SCHEMA} marker")
    data_lines = [line for _, line in data_entries]
    reader = csv.DictReader(data_lines, delimiter="\t")
    if reader.fieldnames != ["shape", "sizes_mib", "rejection_fractions"]:
        raise ValueError(f"{path}: unexpected plan columns")
    for row_index, row in enumerate(reader, 1):
        line_number = data_entries[row_index][0]
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"{path}:{line_number}: wrong plan field count")
        shape = row["shape"]
        if not shape:
            raise ValueError(f"{path}:{line_number}: empty shape")
        if shape in shape_sizes or (shape == "rejection" and rejection_sizes):
            raise ValueError(f"{path}:{line_number}: duplicate shape {shape}")
        try:
            sizes = parse_positive_csv(row["sizes_mib"], "sizes_mib")
            validate_sizes_mib(sizes, "plan size")
        except argparse.ArgumentTypeError as error:
            raise ValueError(f"{path}:{line_number}: {error}") from error
        if shape == "rejection":
            try:
                fractions = parse_positive_csv(
                    row["rejection_fractions"], "rejection_fractions"
                )
            except argparse.ArgumentTypeError as error:
                raise ValueError(f"{path}:{line_number}: {error}") from error
            if any(fraction >= 100 for fraction in fractions):
                raise ValueError(
                    f"{path}:{line_number}: rejection fraction must be between 1 and 99"
                )
            rejection_sizes = {size: fractions for size in sizes}
        else:
            if shape not in SHAPES:
                raise ValueError(f"{path}:{line_number}: unknown shape {shape}")
            if row["rejection_fractions"] not in {"", "-"}:
                raise ValueError(
                    f"{path}:{line_number}: fractions only apply to rejection"
                )
            shape_sizes[shape] = sizes
    if not shape_sizes:
        raise ValueError(f"{path}: plan has no valid workloads")
    return shape_sizes, rejection_sizes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "data" / "generated" / SCHEMA,
    )
    parser.add_argument("--sizes-mib", default="1")
    parser.add_argument("--sizes-kib")
    parser.add_argument("--depths", default="16,256,2048")
    parser.add_argument(
        "--shapes",
        default=",".join(shape for shape in SHAPES if shape != "utf16-text"),
    )
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--summary-program", type=Path)
    parser.add_argument("--no-rejection", action="store_true")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def select_workloads(
    args: argparse.Namespace,
) -> tuple[
    dict[str, list[tuple[str, int]]],
    dict[tuple[str, int], list[int]],
    list[int],
]:
    depths = parse_positive_csv(args.depths, "depths")
    if args.plan:
        if args.sizes_kib is not None:
            raise ValueError("--sizes-kib cannot be combined with --plan")
        shape_sizes_mib, rejection_sizes_mib = read_plan(args.plan)
        if args.no_rejection:
            rejection_sizes_mib = {}
        shape_targets = {
            shape: [(f"{size}m", size * 1024 * 1024) for size in sizes]
            for shape, sizes in shape_sizes_mib.items()
        }
        rejection_targets = {
            (f"{size}m", size * 1024 * 1024): fractions
            for size, fractions in rejection_sizes_mib.items()
        }
    else:
        if args.sizes_kib is not None:
            sizes_kib = parse_positive_csv(args.sizes_kib, "sizes-kib")
            validate_sizes_kib(sizes_kib, "sizes-kib")
            targets = [(f"{size}k", size * 1024) for size in sizes_kib]
        else:
            sizes_mib = parse_positive_csv(args.sizes_mib, "sizes-mib")
            validate_sizes_mib(sizes_mib, "sizes-mib")
            targets = [(f"{size}m", size * 1024 * 1024) for size in sizes_mib]
        shapes = args.shapes.split(",")
        if not shapes or any(not shape for shape in shapes):
            raise ValueError("shapes must not be empty")
        if len(shapes) != len(set(shapes)):
            raise ValueError("shapes must not repeat")
        unknown_shapes = sorted(set(shapes).difference(SHAPES))
        if unknown_shapes:
            raise ValueError("unknown shapes: " + ",".join(unknown_shapes))
        shape_targets = {shape: targets for shape in shapes}
        rejection_targets = (
            {} if args.no_rejection else {target: [1, 50, 99] for target in targets}
        )
    return shape_targets, rejection_targets, depths


def expected_layout(
    shape_targets: dict[str, list[tuple[str, int]]],
    rejection_targets: dict[tuple[str, int], list[int]],
    depths: list[int],
) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for shape, targets in shape_targets.items():
        for size_label, target_bytes in targets:
            item_id = f"{shape}-{size_label}"
            rows.append(
                {
                    "id": item_id,
                    "path": str(Path("valid") / f"{item_id}.xml"),
                    "shape": shape,
                    "target_bytes": str(target_bytes),
                    "actual_bytes": str(target_bytes),
                    "classification": "benchmark-valid",
                    "feature_checks": SHAPE_FEATURES[shape],
                    "rejection_fraction": "-",
                    "fatal_offset": "-",
                    "fatal_fraction": "-",
                }
            )
    for (size_label, target_bytes), fractions in rejection_targets.items():
        for fraction in fractions:
            item_id = f"reject-{fraction:02d}-{size_label}"
            rows.append(
                {
                    "id": item_id,
                    "path": str(Path("invalid") / f"{item_id}.xml"),
                    "shape": "rejection",
                    "target_bytes": str(target_bytes),
                    "actual_bytes": str(target_bytes),
                    "classification": "not-well-formed",
                    "feature_checks": "check_element_matching",
                    "rejection_fraction": str(fraction),
                }
            )
    for depth in depths:
        item_id = f"deep-{depth}"
        rows.append(
            {
                "id": item_id,
                "path": str(Path("valid") / f"{item_id}.xml"),
                "shape": "deep",
                "target_bytes": "0",
                "actual_bytes": str(depth * 7 + 1),
                "classification": "benchmark-valid",
                "feature_checks": f"document,element_matching,depth_{depth}",
                "rejection_fraction": "-",
                "fatal_offset": "-",
                "fatal_fraction": "-",
            }
        )
    return rows


def verify(
    output_dir: Path,
    plan: Path | None,
    shape_targets: dict[str, list[tuple[str, int]]],
    rejection_targets: dict[tuple[str, int], list[int]],
    depths: list[int],
) -> int:
    manifest = output_dir / "manifest.tsv"
    if not manifest.is_file():
        print(f"missing generated manifest: {manifest}", file=sys.stderr)
        return 1
    errors: list[str] = []
    try:
        lines = manifest.read_text(encoding="utf-8").splitlines(keepends=True)
    except OSError as error:
        print(error, file=sys.stderr)
        return 1
    comments = [line[1:].strip() for line in lines if line.startswith("#")]
    schema_markers = [
        comment for comment in comments if comment.startswith("z-xml-generated-")
    ]
    if schema_markers != [SCHEMA]:
        errors.append(f"manifest must contain exactly one {SCHEMA} marker")
    if comments.count(f"size ceiling: {MAX_TARGET_BYTES} bytes") != 1:
        errors.append("manifest has an unexpected size ceiling")
    if plan is not None:
        if comments.count(f"plan_name: {plan.name}") != 1:
            errors.append("manifest plan name differs")
    elif any(comment.startswith("plan_name:") for comment in comments):
        errors.append("manifest unexpectedly names a plan")
    summary_comments = [
        comment for comment in comments if comment.startswith("summary_program:")
    ]
    if len(summary_comments) > 1:
        errors.append("manifest names more than one summary program")
    elif (
        summary_comments
        and not summary_comments[0].removeprefix("summary_program:").strip()
    ):
        errors.append("manifest has an empty summary program")
    expected_comments = [SCHEMA, f"size ceiling: {MAX_TARGET_BYTES} bytes"]
    if plan is not None:
        expected_comments.append(f"plan_name: {plan.name}")
    if summary_comments:
        expected_comments.append(summary_comments[0])
    if comments != expected_comments:
        errors.append("manifest comments differ")
    data_entries = [
        (line_number, line)
        for line_number, line in enumerate(lines, 1)
        if line.strip() and not line.startswith("#")
    ]
    data_lines = [line for _, line in data_entries]
    reader = csv.DictReader(data_lines, delimiter="\t")
    if reader.fieldnames != MANIFEST_COLUMNS:
        errors.append("manifest has unexpected columns")
        print("\n".join(errors), file=sys.stderr)
        return 1
    rows = list(reader)
    if not rows:
        errors.append("manifest has no workloads")
    for row_index, row in enumerate(rows, 1):
        if None in row or any(value is None for value in row.values()):
            errors.append(f"manifest:{data_entries[row_index][0]}: wrong field count")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    canonical_data = io.StringIO(newline="")
    canonical_writer = csv.DictWriter(
        canonical_data,
        fieldnames=MANIFEST_COLUMNS,
        delimiter="\t",
        lineterminator="\n",
    )
    canonical_writer.writeheader()
    canonical_writer.writerows(rows)
    canonical_manifest = (
        "".join(f"# {comment}\n" for comment in expected_comments)
        + canonical_data.getvalue()
    )
    if "".join(lines) != canonical_manifest:
        print("manifest is not in canonical form", file=sys.stderr)
        return 1
    expected_rows = expected_layout(shape_targets, rejection_targets, depths)
    if [row["id"] for row in rows] != [row["id"] for row in expected_rows]:
        errors.append("manifest workload rows differ from the requested configuration")
    seen_ids: set[str] = set()
    expected_paths: set[Path] = set()
    root = output_dir.resolve()
    expected_by_id = {row["id"]: row for row in expected_rows}
    for row in rows:
        item_id = row.get("id", "<missing-id>")
        if item_id in seen_ids:
            errors.append(f"{item_id}: duplicate workload ID")
        seen_ids.add(item_id)
        expected = expected_by_id.get(item_id)
        if expected is None:
            continue
        for field, value in expected.items():
            dynamic_rejection_field = expected[
                "classification"
            ] == "not-well-formed" and field in {"fatal_offset", "fatal_fraction"}
            if not dynamic_rejection_field and row[field] != value:
                errors.append(f"{item_id}: {field} differs")
        try:
            path = (root / row["path"]).resolve()
            path.relative_to(root)
            relative_path = path.relative_to(root)
            data_size = path.stat().st_size
            manifest_size = int(row["actual_bytes"])
            target_bytes = int(row["target_bytes"])
        except (KeyError, OSError, ValueError) as error:
            errors.append(f"{item_id}: {error}")
            continue
        if relative_path in expected_paths:
            errors.append(f"{item_id}: duplicate workload path")
        expected_paths.add(relative_path)
        if data_size != manifest_size:
            errors.append(f"{item_id}: size differs")
        if target_bytes and data_size != target_bytes:
            errors.append(f"{item_id}: generated size differs from target")
        if data_size > MAX_TARGET_BYTES:
            errors.append(f"{item_id}: exceeds the 1 GiB ceiling")
        try:
            if not generated_bytes_match(path, row):
                errors.append(f"{item_id}: generated bytes differ")
        except (KeyError, OSError, TypeError, ValueError) as error:
            errors.append(f"{item_id}: cannot verify generated bytes: {error}")
        if row["classification"] == "benchmark-valid":
            try:
                summary = Stats.from_json(json.loads(row["expected_summary"]))
                if (
                    row["elements"] != str(summary.elements)
                    or row["attributes"] != str(summary.attributes)
                    or row["normalized_text_bytes"] != str(summary.text_bytes)
                    or row["expected_summary"] != summary.compact_json()
                ):
                    raise ValueError("summary columns disagree")
            except (json.JSONDecodeError, TypeError, ValueError) as error:
                errors.append(f"{item_id}: invalid semantic summary: {error}")
        elif row["classification"] == "not-well-formed":
            if any(
                row[field] != "-"
                for field in (
                    "elements",
                    "attributes",
                    "normalized_text_bytes",
                    "expected_summary",
                )
            ):
                errors.append(f"{item_id}: rejection has semantic summary fields")
            try:
                requested_fraction = int(row["rejection_fraction"])
                fatal_offset = int(row["fatal_offset"])
                declared_fraction = float(row["fatal_fraction"])
                actual_fraction = fatal_offset * 100 / data_size
                expected_offset = rejection_offset(data_size, requested_fraction)
                with path.open("rb") as input_stream:
                    input_stream.seek(fatal_offset)
                    fatal_construct = input_stream.read(len(b"</bad>"))
            except (KeyError, OSError, ValueError) as error:
                errors.append(f"{item_id}: invalid rejection metadata: {error}")
            else:
                if (
                    requested_fraction < 1
                    or requested_fraction > 99
                    or fatal_offset < 0
                    or fatal_offset + len(b"</bad>") > data_size
                    or abs(declared_fraction - actual_fraction) > 0.000001
                    or fatal_offset != expected_offset
                    or row["fatal_offset"] != str(expected_offset)
                    or row["fatal_fraction"] != f"{actual_fraction:.6f}"
                    or fatal_construct != b"</bad>"
                ):
                    errors.append(f"{item_id}: rejection position differs")
        else:
            errors.append(f"{item_id}: unsupported classification")
    actual_paths = {
        path.resolve().relative_to(root)
        for path in output_dir.rglob("*")
        if path.is_file() and path.resolve() != manifest.resolve()
    }
    for unexpected in sorted(actual_paths.difference(expected_paths)):
        errors.append(f"unexpected generated file: {unexpected}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"verified generated corpus at {output_dir}")
    return 0


def main() -> int:
    args = parse_args()
    try:
        shape_targets, rejection_targets, depths = select_workloads(args)
        if args.summary_program:
            args.summary_program = args.summary_program.resolve()
            if not args.summary_program.is_file():
                raise ValueError(f"missing summary program: {args.summary_program}")
    except (argparse.ArgumentTypeError, OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 64
    if args.check:
        return verify(
            args.output_dir,
            args.plan,
            shape_targets,
            rejection_targets,
            depths,
        )

    rows: list[dict[str, str | int]] = []
    for shape, targets in shape_targets.items():
        for size_label, target_bytes in targets:
            item_id = f"{shape}-{size_label}"
            relative = Path("valid") / f"{item_id}.xml"

            def shape_generator(
                output: Output, selected: str = shape, size: int = target_bytes
            ) -> Stats | None:
                stats = None if args.summary_program else Stats()
                generate_shape(output, stats, selected, size)
                return stats

            actual, stats = atomic_generate(args.output_dir / relative, shape_generator)
            if args.summary_program:
                stats = collect_summary(
                    args.summary_program, args.output_dir / relative
                )
            assert stats is not None
            rows.append(
                {
                    "id": item_id,
                    "path": str(relative),
                    "shape": shape,
                    "target_bytes": target_bytes,
                    "actual_bytes": actual,
                    "classification": "benchmark-valid",
                    "feature_checks": SHAPE_FEATURES[shape],
                    "rejection_fraction": "-",
                    "fatal_offset": "-",
                    "fatal_fraction": "-",
                    "elements": stats.elements,
                    "attributes": stats.attributes,
                    "normalized_text_bytes": stats.text_bytes,
                    "expected_summary": stats.compact_json(),
                }
            )

    for (size_label, target_bytes), fractions in rejection_targets.items():
        for fraction in fractions:
            item_id = f"reject-{fraction:02d}-{size_label}"
            relative = Path("invalid") / f"{item_id}.xml"

            fatal_offset = 0

            def rejection_generator(
                output: Output, size: int = target_bytes, position: int = fraction
            ) -> None:
                nonlocal fatal_offset
                fatal_offset = generate_rejection(output, size, position)

            actual, _ = atomic_generate(args.output_dir / relative, rejection_generator)
            rows.append(
                {
                    "id": item_id,
                    "path": str(relative),
                    "shape": "rejection",
                    "target_bytes": target_bytes,
                    "actual_bytes": actual,
                    "classification": "not-well-formed",
                    "feature_checks": "check_element_matching",
                    "rejection_fraction": fraction,
                    "fatal_offset": fatal_offset,
                    "fatal_fraction": f"{fatal_offset * 100 / actual:.6f}",
                    "elements": "-",
                    "attributes": "-",
                    "normalized_text_bytes": "-",
                    "expected_summary": "-",
                }
            )

    for depth in depths:
        item_id = f"deep-{depth}"
        relative = Path("valid") / f"{item_id}.xml"

        def deep_generator(output: Output, selected_depth: int = depth) -> Stats:
            stats = Stats()
            generate_deep(output, stats, selected_depth)
            return stats

        actual, stats = atomic_generate(args.output_dir / relative, deep_generator)
        assert stats is not None
        rows.append(
            {
                "id": item_id,
                "path": str(relative),
                "shape": "deep",
                "target_bytes": 0,
                "actual_bytes": actual,
                "classification": "benchmark-valid",
                "feature_checks": f"document,element_matching,depth_{depth}",
                "rejection_fraction": "-",
                "fatal_offset": "-",
                "fatal_fraction": "-",
                "elements": stats.elements,
                "attributes": stats.attributes,
                "normalized_text_bytes": stats.text_bytes,
                "expected_summary": stats.compact_json(),
            }
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest = args.output_dir / "manifest.tsv"
    temporary = manifest.with_name(manifest.name + ".tmp")
    fieldnames = MANIFEST_COLUMNS
    try:
        with temporary.open("w", encoding="utf-8", newline="") as stream:
            stream.write(f"# {SCHEMA}\n")
            stream.write(f"# size ceiling: {MAX_TARGET_BYTES} bytes\n")
            if args.plan:
                stream.write(f"# plan_name: {args.plan.name}\n")
            if args.summary_program:
                stream.write(f"# summary_program: {args.summary_program.name}\n")
            writer = csv.DictWriter(
                stream, fieldnames=fieldnames, delimiter="\t", lineterminator="\n"
            )
            writer.writeheader()
            writer.writerows(rows)
        temporary.replace(manifest)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    print(f"generated {len(rows)} workloads at {args.output_dir}")
    return 0


if __name__ == "__main__":
    try:
        status = main()
    except (OSError, TypeError, ValueError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        status = 1
    raise SystemExit(status)
