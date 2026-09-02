#!/usr/bin/env python3
"""Generate deterministic reusable-validation workloads and exact results."""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from pathlib import Path

from generated_tree import default_output, generate_or_check

SCHEMA = "z-xml-validation-reuse-v1"
SMALL_BYTES = 16 * 1024
LARGE_BYTES = 64 * 1024 * 1024
FNV_OFFSET = 14695981039346656037
FNV_PRIME = 1099511628211
PAYLOAD_BYTES = 960
DTD_NAME = "reuse.dtd"
MANIFEST_COLUMNS = [
    "id",
    "path",
    "actual_bytes",
    "classification",
    "resource_paths",
    "targets",
    "program_args",
    "expected_result",
]


def fnv_update(value: int, data: bytes) -> int:
    for byte in data:
        value ^= byte
        value = (value * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


@dataclass(frozen=True)
class Location:
    source_id: int
    offset: int


@dataclass(frozen=True)
class Finding:
    code: str
    primary: Location
    related: Location | None = None
    inclusion_trace: tuple[Location, ...] = ()


def finding_checksum(findings: tuple[Finding, ...]) -> str:
    value = FNV_OFFSET
    for finding in findings:
        value = fnv_update(value, finding.code.encode() + b"\0")
        value = fnv_update(value, finding.primary.source_id.to_bytes(8, "little"))
        value = fnv_update(value, finding.primary.offset.to_bytes(8, "little"))
        value = fnv_update(value, b"\1" if finding.related else b"\0")
        if finding.related:
            value = fnv_update(value, finding.related.source_id.to_bytes(8, "little"))
            value = fnv_update(value, finding.related.offset.to_bytes(8, "little"))
        value = fnv_update(value, len(finding.inclusion_trace).to_bytes(8, "little"))
        for location in finding.inclusion_trace:
            value = fnv_update(value, location.source_id.to_bytes(8, "little"))
            value = fnv_update(value, location.offset.to_bytes(8, "little"))
    return f"{value:016x}"


@dataclass
class Stats:
    elements: int = 0
    attributes: int = 0
    defaulted_attributes: int = 0
    text_bytes: int = 0
    checksum: int = FNV_OFFSET

    def start(self, name: bytes, attributes: tuple[tuple[bytes, bytes], ...]) -> None:
        self.elements += 1
        self.checksum = fnv_update(self.checksum, b"\1" + name)
        for attr_name, attr_value in attributes:
            self.attributes += 1
            self.checksum = fnv_update(
                self.checksum, b"\2" + attr_name + b"\3" + attr_value
            )

    def text(self, value: bytes) -> None:
        self.text_bytes += len(value)
        self.checksum = fnv_update(self.checksum, value)

    def end(self, name: bytes) -> None:
        self.checksum = fnv_update(self.checksum, b"\4" + name)


@dataclass(frozen=True)
class GeneratedDocument:
    stats: Stats
    item_count: int
    findings: tuple[Finding, ...]
    id_count: int
    idref_count: int


@dataclass(frozen=True)
class Workload:
    name: str
    path: Path
    resources: tuple[Path, ...]
    arguments: tuple[str, ...]
    primary: GeneratedDocument
    next_document: GeneratedDocument | None = None


def item_record(index: int, payload: bytes, duplicate: bool = False) -> bytes:
    identifier = b"i000000" if duplicate else f"i{index:06d}".encode()
    reference = b"missing" if duplicate else identifier
    return (
        b'<item id="'
        + identifier
        + b'" ref="'
        + reference
        + b'">'
        + payload
        + b"</item>"
    )


def observe_item(stats: Stats, index: int, payload: bytes, duplicate: bool) -> None:
    identifier = b"i000000" if duplicate else f"i{index:06d}".encode()
    reference = b"missing" if duplicate else identifier
    stats.start(b"item", ((b"id", identifier), (b"ref", reference)))
    if payload:
        stats.text(payload)
    stats.end(b"item")


def generate_document(
    path: Path, target_bytes: int, invalid: bool
) -> GeneratedDocument:
    prefix = b"<!DOCTYPE root SYSTEM 'reuse.dtd'><root>"
    suffix = b"</root>"
    full_record = item_record(0, b"x" * PAYLOAD_BYTES)
    final_markup = len(item_record(0, b""))
    available = target_bytes - len(prefix) - len(suffix)
    full_count = (available - final_markup) // len(full_record)
    final_payload_bytes = available - full_count * len(full_record) - final_markup
    if full_count < 2 or not 0 <= final_payload_bytes < len(full_record):
        raise ValueError("invalid generated document layout")

    stats = Stats()
    stats.start(b"root", ())
    second_offset = 0
    with path.open("wb") as stream:
        stream.write(prefix)
        for index in range(full_count):
            duplicate = invalid and index == 1
            if duplicate:
                second_offset = stream.tell()
            payload = b"x" * PAYLOAD_BYTES
            stream.write(item_record(index, payload, duplicate))
            observe_item(stats, index, payload, duplicate)
        final_payload = b"x" * final_payload_bytes
        final_index = full_count
        stream.write(item_record(final_index, final_payload))
        observe_item(stats, final_index, final_payload, False)
        stream.write(suffix)
    stats.end(b"root")

    item_count = full_count + 1
    findings: tuple[Finding, ...] = ()
    id_count = item_count
    if invalid:
        findings = (
            Finding("validity_duplicate_id", Location(0, second_offset + 6)),
            Finding(
                "validity_unresolved_idref",
                Location(0, second_offset + len(b'<item id="i000000" ')),
            ),
        )
        id_count -= 1
    if path.stat().st_size != target_bytes:
        raise ValueError(f"{path}: generated size differs")
    return GeneratedDocument(stats, item_count, findings, id_count, item_count)


def semantic_result(document: GeneratedDocument) -> dict[str, object]:
    findings = document.findings
    return {
        "elements": document.stats.elements,
        "attributes": document.stats.attributes,
        "defaulted_attributes": document.stats.defaulted_attributes,
        "text_bytes": document.stats.text_bytes,
        "event_checksum": f"{document.stats.checksum:016x}",
        "content": "complete",
        "validity": "invalid" if findings else "valid",
        "findings": len(findings),
        "findings_checksum": finding_checksum(findings),
        "first_finding": findings[0].code if findings else None,
        "first_finding_source_id": findings[0].primary.source_id if findings else None,
        "first_finding_offset": findings[0].primary.offset if findings else None,
        "last_finding": findings[-1].code if findings else None,
        "last_finding_source_id": findings[-1].primary.source_id if findings else None,
        "last_finding_offset": findings[-1].primary.offset if findings else None,
        "id_count": document.id_count,
        "idref_count": document.idref_count,
    }


def build(output: Path) -> None:
    valid = output / "valid"
    invalid = output / "invalid"
    valid.mkdir(parents=True)
    invalid.mkdir(parents=True)

    dtd = (
        b"<!ELEMENT root (item*)>\n"
        b"<!ELEMENT item (#PCDATA)>\n"
        b"<!ATTLIST item id ID #REQUIRED ref IDREF #IMPLIED>\n"
    )
    dtd_path = valid / DTD_NAME
    dtd_path.write_bytes(dtd)
    small_path = valid / "reuse-16k.xml"
    small = generate_document(small_path, SMALL_BYTES, False)
    large_path = valid / "reuse-64m.xml"
    large = generate_document(large_path, LARGE_BYTES, False)
    invalid_path = invalid / "reuse-invalid-16k.xml"
    invalid_document = generate_document(invalid_path, SMALL_BYTES, True)
    invalid_dtd = invalid / DTD_NAME
    invalid_dtd.write_bytes(dtd)

    targets = "z-xml-validation-fresh,z-xml-validation-reused"
    workloads = (
        Workload(
            "validation-reuse-small",
            small_path,
            (dtd_path,),
            ("--dtd=reuse.dtd", "--iterations=4096"),
            small,
        ),
        Workload(
            "validation-reuse-large",
            large_path,
            (dtd_path,),
            ("--dtd=reuse.dtd", "--iterations=8"),
            large,
        ),
        Workload(
            "validation-reuse-large-small",
            large_path,
            (dtd_path, small_path),
            (
                "--dtd=reuse.dtd",
                "--iterations=1",
                "--next-file=reuse-16k.xml",
                "--next-iterations=4096",
            ),
            large,
            small,
        ),
        Workload(
            "validation-reuse-invalid",
            invalid_path,
            (invalid_dtd,),
            ("--dtd=reuse.dtd", "--iterations=2"),
            invalid_document,
        ),
    )

    with (output / "manifest.tsv").open("w", encoding="utf-8", newline="") as stream:
        stream.write(f"# {SCHEMA}\n")
        writer = csv.DictWriter(
            stream, MANIFEST_COLUMNS, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        for workload in workloads:
            expected = {
                "primary": semantic_result(workload.primary),
                "next": (
                    semantic_result(workload.next_document)
                    if workload.next_document
                    else None
                ),
            }
            writer.writerow(
                {
                    "id": workload.name,
                    "path": workload.path.relative_to(output),
                    "actual_bytes": workload.path.stat().st_size,
                    "classification": "benchmark-valid",
                    "resource_paths": ",".join(
                        str(path.relative_to(output)) for path in workload.resources
                    ),
                    "targets": targets,
                    "program_args": " ".join(workload.arguments),
                    "expected_result": json.dumps(
                        expected, separators=(",", ":"), sort_keys=True
                    ),
                }
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=default_output(SCHEMA),
    )
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return generate_or_check(
        args.output_dir,
        check=args.check,
        temporary_prefix="z-xml-validation-reuse-",
        label="validation reuse corpus",
        build=build,
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(error)
        raise SystemExit(1) from error
