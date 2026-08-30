#!/usr/bin/env python3
"""Generate deterministic DTD processing workloads and exact expected results."""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

SCHEMA = "z-xml-dtd-generated-v1"
TARGET_BYTES = 64 * 1024 * 1024
SYNTAX_BYTES = 64 * 1024
FNV_OFFSET = 14695981039346656037
FNV_PRIME = 1099511628211
MANIFEST_COLUMNS = [
    "id",
    "path",
    "actual_bytes",
    "classification",
    "resource_paths",
    "targets",
    "program_args",
    "expected_status",
    "expected_result",
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
    defaulted_attributes: int = 0
    text_bytes: int = 0
    checksum: int = FNV_OFFSET

    def start(
        self,
        name: bytes,
        attributes: tuple[tuple[bytes, bytes, bool], ...] = (),
    ) -> None:
        self.elements += 1
        self.checksum = fnv_update(self.checksum, b"\x01" + name)
        for attr_name, attr_value, specified in attributes:
            self.attributes += 1
            if not specified:
                self.defaulted_attributes += 1
            self.checksum = fnv_update(
                self.checksum, b"\x02" + attr_name + b"\x03" + attr_value
            )

    def text(self, value: bytes) -> None:
        self.text_bytes += len(value)
        self.checksum = fnv_update(self.checksum, value)

    def end(self, name: bytes) -> None:
        self.checksum = fnv_update(self.checksum, b"\x04" + name)


@dataclass
class SourceStats:
    resolver_calls: int = 0
    resolved_sources: int = 0
    closed_sources: int = 0
    unavailable_results: int = 0
    failure_results: int = 0
    external_subset_sources: int = 0
    parameter_entity_sources: int = 0
    general_entity_sources: int = 0
    skipped_sources: int = 0
    source_bytes: int = 0


@dataclass
class Failure:
    error: str
    diagnostic: str
    source_id: int
    offset: int
    related_source_id: int | None = None
    related_offset: int | None = None
    inclusion_depth: int = 0


@dataclass
class Case:
    name: str
    path: Path
    classification: str
    targets: tuple[str, ...]
    program_args: tuple[str, ...]
    expected_status: int
    stats: Stats
    content: str | None
    sources: SourceStats = field(default_factory=SourceStats)
    resources: tuple[Path, ...] = ()
    failure: Failure | None = None


def result(case: Case) -> dict[str, object]:
    failure = case.failure
    return {
        "outcome": "failure" if failure else "success",
        "error": failure.error if failure else None,
        "diagnostic": failure.diagnostic if failure else None,
        "source_id": failure.source_id if failure else None,
        "offset": failure.offset if failure else None,
        "related_source_id": failure.related_source_id if failure else None,
        "related_offset": failure.related_offset if failure else None,
        "inclusion_depth": failure.inclusion_depth if failure else 0,
        "elements": case.stats.elements,
        "attributes": case.stats.attributes,
        "defaulted_attributes": case.stats.defaulted_attributes,
        "text_bytes": case.stats.text_bytes,
        "checksum": f"{case.stats.checksum:016x}",
        "content": case.content,
        "resolver_calls": case.sources.resolver_calls,
        "resolved_sources": case.sources.resolved_sources,
        "closed_sources": case.sources.closed_sources,
        "unavailable_results": case.sources.unavailable_results,
        "failure_results": case.sources.failure_results,
        "external_subset_sources": case.sources.external_subset_sources,
        "parameter_entity_sources": case.sources.parameter_entity_sources,
        "general_entity_sources": case.sources.general_entity_sources,
        "skipped_sources": case.sources.skipped_sources,
        "source_bytes": case.sources.source_bytes,
    }


def write_repeated(stream, record: bytes, count: int) -> None:
    per_block = max(1, (1024 * 1024) // len(record))
    block = record * per_block
    while count >= per_block:
        stream.write(block)
        count -= per_block
    if count:
        stream.write(record * count)


def generate_declarations(path: Path) -> Stats:
    names = tuple(f"e{index:02d}".encode() for index in range(64))
    declarations = b"".join(
        b"<!ELEMENT " + name + b" (#PCDATA)>"
        b"<!ATTLIST " + name + b" kind CDATA 'default'>"
        for name in names
    )
    prefix = b"<!DOCTYPE root [<!ELEMENT root ANY>" + declarations + b"]><root>"
    suffix = b"</root>"
    text = b"x" * 224
    records = tuple(b"<" + name + b">" + text + b"</" + name + b">" for name in names)
    cycle = b"".join(records)
    available = TARGET_BYTES - len(prefix) - len(suffix)
    cycles, remainder = divmod(available, len(cycle))
    stats = Stats()
    stats.start(b"root")
    with path.open("wb") as stream:
        stream.write(prefix)
        for _ in range(cycles):
            stream.write(cycle)
            for name in names:
                stats.start(name, ((b"kind", b"default", False),))
                stats.text(text)
                stats.end(name)
        for name, record in zip(names, records, strict=True):
            if len(record) > remainder:
                break
            stream.write(record)
            remainder -= len(record)
            stats.start(name, ((b"kind", b"default", False),))
            stats.text(text)
            stats.end(name)
        if remainder:
            filler = b"x" * remainder
            stream.write(filler)
            stats.text(filler)
        stream.write(suffix)
    stats.end(b"root")
    return stats


def generate_entities(path: Path) -> Stats:
    prefix = b"<!DOCTYPE root [<!ELEMENT root (#PCDATA)><!ENTITY e 'entity'>]><root>"
    suffix = b"</root>"
    record = b"&e;" + b"x" * 61
    available = TARGET_BYTES - len(prefix) - len(suffix)
    count, remainder = divmod(available, len(record))
    stats = Stats()
    stats.start(b"root")
    with path.open("wb") as stream:
        stream.write(prefix)
        write_repeated(stream, record, count)
        for _ in range(count):
            stats.text(b"entity")
            stats.text(record[3:])
        if remainder:
            filler = b"x" * remainder
            stream.write(filler)
            stats.text(filler)
        stream.write(suffix)
    stats.end(b"root")
    return stats


def generate_external(path: Path) -> tuple[Stats, Stats, bytes, bytes, bytes]:
    subset = b"<!ENTITY % declarations SYSTEM 'declarations.ent'>%declarations;"
    declarations = (
        b"<!ELEMENT root ANY><!ELEMENT item (#PCDATA)>"
        b"<!ATTLIST item kind CDATA 'external-default'>"
    )
    entity = b"external-value"
    prefix = (
        b"<!DOCTYPE root SYSTEM 'external.dtd' "
        b"[<!ENTITY ext SYSTEM 'value.ent'>]><root>&ext;"
    )
    suffix = b"</root>"
    text = b"x" * 224
    record = b"<item>" + text + b"</item>"
    available = TARGET_BYTES - len(prefix) - len(suffix)
    count, remainder = divmod(available, len(record))
    stats = Stats()
    stats.start(b"root")
    stats.text(entity)
    skip_stats = Stats()
    skip_stats.start(b"root")
    with path.open("wb") as stream:
        stream.write(prefix)
        write_repeated(stream, record, count)
        for _ in range(count):
            stats.start(b"item", ((b"kind", b"external-default", False),))
            stats.text(text)
            stats.end(b"item")
            skip_stats.start(b"item")
            skip_stats.text(text)
            skip_stats.end(b"item")
        if remainder:
            filler = b"x" * remainder
            stream.write(filler)
            stats.text(filler)
            skip_stats.text(filler)
        stream.write(suffix)
    stats.end(b"root")
    skip_stats.end(b"root")
    return stats, skip_stats, subset, declarations, entity


def generate_markup(path: Path) -> Stats:
    prefix = b"<root>"
    suffix = b"</root>"
    record = b"<n/>"
    available = TARGET_BYTES - len(prefix) - len(suffix)
    count, remainder = divmod(available, len(record))
    stats = Stats()
    stats.start(b"root")
    with path.open("wb") as stream:
        stream.write(prefix)
        write_repeated(stream, record, count)
        for _ in range(count):
            stats.start(b"n")
            stats.end(b"n")
        if remainder:
            filler = b"x" * remainder
            stream.write(filler)
            stats.text(filler)
        stream.write(suffix)
    stats.end(b"root")
    return stats


def write_file(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def simple_stats(root_text: bytes | None = None) -> Stats:
    stats = Stats()
    stats.start(b"r")
    if root_text is not None:
        stats.text(root_text)
    stats.end(b"r")
    return stats


def started_stats() -> Stats:
    stats = Stats()
    stats.start(b"r")
    return stats


def build(output: Path) -> None:
    valid = output / "valid"
    invalid = output / "invalid"
    valid.mkdir(parents=True)
    invalid.mkdir(parents=True)

    declarations_path = valid / "declarations-64m.xml"
    declarations_stats = generate_declarations(declarations_path)
    entities_path = valid / "entities-64m.xml"
    entities_stats = generate_entities(entities_path)
    external_path = valid / "external-64m.xml"
    (
        external_stats,
        external_skip_stats,
        subset,
        external_declarations,
        external_entity,
    ) = generate_external(external_path)
    external_subset_path = valid / "external.dtd"
    external_declarations_path = valid / "declarations.ent"
    external_entity_path = valid / "value.ent"
    write_file(external_subset_path, subset)
    write_file(external_declarations_path, external_declarations)
    write_file(external_entity_path, external_entity)
    external_resources = (
        external_subset_path,
        external_declarations_path,
        external_entity_path,
    )
    external_bytes = sum(path.stat().st_size for path in external_resources)

    markup_path = valid / "no-doctype-64m.xml"
    markup_stats = generate_markup(markup_path)

    syntax_input = b"<!DOCTYPE root [<!--" + b"x" * (SYNTAX_BYTES - 70)
    syntax_input += b"--><!ELEMENT root (a|)>]><root/>"
    syntax_path = invalid / "syntax-64k.xml"
    write_file(syntax_path, syntax_input)
    recursion_input = (
        b"<!DOCTYPE r [<!ELEMENT r (#PCDATA)><!ENTITY a '&b;'>"
        b"<!ENTITY b '&a;'>]><r>&a;</r>"
    )
    recursion_path = invalid / "recursive-entity.xml"
    write_file(recursion_path, recursion_input)

    resource_input = b"<!DOCTYPE r SYSTEM 'missing.dtd'><r/>"
    resource_path = invalid / "external-resource.xml"
    write_file(resource_path, resource_input)

    dtd_at_path = valid / "dtd-bytes-at.xml"
    dtd_over_path = invalid / "dtd-bytes-over.xml"
    write_file(dtd_at_path, b"<!DOCTYPE r><r/>")
    write_file(dtd_over_path, b"<!DOCTYPE rr><r/>")
    expansion_at_input = b"<!DOCTYPE r [<!ENTITY % a '&#60;!ELEMENT r EMPTY>'>%a;]><r/>"
    expansion_over_input = (
        b"<!DOCTYPE r [<!ENTITY % a '&#60;!ELEMENT r EMPTY>'>%a;%a;]><r/>"
    )
    expansion_at_path = valid / "expansion-at.xml"
    expansion_over_path = invalid / "expansion-over.xml"
    write_file(expansion_at_path, expansion_at_input)
    write_file(expansion_over_path, expansion_over_input)
    external_bytes_input = b"<!DOCTYPE r [<!ENTITY a SYSTEM 'two.ent'>]><r>&a;</r>"
    external_bytes_path = valid / "external-bytes.xml"
    external_bytes_resource = valid / "two.ent"
    write_file(external_bytes_path, external_bytes_input)
    write_file(external_bytes_resource, b"xy")

    dtd_args = ("--dtd-report", "--external=forbid")
    cases = [
        Case(
            "declarations-64m",
            declarations_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            dtd_args,
            0,
            declarations_stats,
            "complete",
        ),
        Case(
            "entities-64m",
            entities_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            dtd_args,
            0,
            entities_stats,
            "complete",
        ),
        Case(
            "external-resolve-64m",
            external_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            ("--dtd-report", "--external=resolve"),
            0,
            external_stats,
            "complete",
            SourceStats(
                resolver_calls=3,
                resolved_sources=3,
                closed_sources=3,
                external_subset_sources=1,
                parameter_entity_sources=1,
                general_entity_sources=1,
                source_bytes=external_bytes,
            ),
            external_resources,
        ),
        Case(
            "external-skip-64m",
            external_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            ("--dtd-report", "--external=skip"),
            0,
            external_skip_stats,
            "external_content_skipped",
            SourceStats(skipped_sources=2),
        ),
        Case(
            "syntax-64k",
            syntax_path,
            "not-well-formed",
            ("z-xml-dtd-process",),
            dtd_args,
            2,
            Stats(),
            None,
            failure=Failure(
                "InvalidXml",
                "malformed_element_declaration",
                0,
                syntax_input.index(b")"),
            ),
        ),
        Case(
            "recursive-entity",
            recursion_path,
            "not-well-formed",
            ("z-xml-dtd-process",),
            dtd_args,
            2,
            started_stats(),
            None,
            failure=Failure(
                "InvalidXml",
                "recursive_entity",
                0,
                len(recursion_input) - 1,
            ),
        ),
        Case(
            "external-unavailable",
            resource_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            ("--dtd-report", "--external=unavailable"),
            1,
            Stats(),
            None,
            SourceStats(resolver_calls=1, unavailable_results=1),
            failure=Failure(
                "ExternalResourceUnavailable",
                "resolver_not_found",
                0,
                resource_input.index(b"DOCTYPE") + len(b"DOCTYPE"),
            ),
        ),
        Case(
            "external-failure",
            resource_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            ("--dtd-report", "--external=failure"),
            1,
            Stats(),
            None,
            SourceStats(resolver_calls=1, failure_results=1),
            failure=Failure(
                "ExternalResourceFailed",
                "resolver_io_failure",
                0,
                resource_input.index(b"DOCTYPE") + len(b"DOCTYPE"),
            ),
        ),
        Case(
            "dtd-bytes-at",
            dtd_at_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            (*dtd_args, "--max-dtd-bytes=3"),
            0,
            simple_stats(),
            "complete",
        ),
        Case(
            "dtd-bytes-over",
            dtd_over_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            (*dtd_args, "--max-dtd-bytes=3"),
            3,
            Stats(),
            None,
            failure=Failure("LimitExceeded", "dtd_bytes_limit", 0, 0),
        ),
        Case(
            "expansion-at",
            expansion_at_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            (*dtd_args, "--max-dtd-expanded-bytes=18"),
            0,
            simple_stats(),
            "complete",
        ),
        Case(
            "expansion-over",
            expansion_over_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            (*dtd_args, "--max-dtd-expanded-bytes=18"),
            3,
            Stats(),
            None,
            failure=Failure(
                "LimitExceeded",
                "entity_expansion_limit",
                0,
                expansion_over_input.rindex(b"%a;") + len(b"%a;"),
            ),
        ),
        Case(
            "external-bytes-at",
            external_bytes_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            (
                "--dtd-report",
                "--external=resolve",
                "--max-external-source-bytes=2",
            ),
            0,
            simple_stats(b"xy"),
            "complete",
            SourceStats(
                resolver_calls=1,
                resolved_sources=1,
                closed_sources=1,
                general_entity_sources=1,
                source_bytes=2,
            ),
            (external_bytes_resource,),
        ),
        Case(
            "external-bytes-over",
            external_bytes_path,
            "benchmark-valid",
            ("z-xml-dtd-process",),
            (
                "--dtd-report",
                "--external=resolve",
                "--max-external-source-bytes=1",
            ),
            3,
            started_stats(),
            None,
            SourceStats(
                resolver_calls=1,
                resolved_sources=1,
                closed_sources=1,
                general_entity_sources=1,
                source_bytes=2,
            ),
            (external_bytes_resource,),
            Failure(
                "LimitExceeded",
                "external_resource_bytes_limit",
                1,
                0,
                inclusion_depth=1,
            ),
        ),
        Case(
            "no-doctype-64m",
            markup_path,
            "benchmark-valid",
            ("z-xml-dtd-process-control", "z-xml-dtd-reject-control"),
            dtd_args,
            0,
            markup_stats,
            "complete",
        ),
    ]

    manifest = output / "manifest.tsv"
    with manifest.open("w", encoding="utf-8", newline="") as stream:
        stream.write(f"# {SCHEMA}\n")
        writer = csv.DictWriter(
            stream, MANIFEST_COLUMNS, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        for case in cases:
            writer.writerow(
                {
                    "id": case.name,
                    "path": case.path.relative_to(output),
                    "actual_bytes": case.path.stat().st_size,
                    "classification": case.classification,
                    "resource_paths": ",".join(
                        str(path.relative_to(output)) for path in case.resources
                    )
                    or "-",
                    "targets": ",".join(case.targets),
                    "program_args": " ".join(case.program_args),
                    "expected_status": case.expected_status,
                    "expected_result": json.dumps(
                        result(case), separators=(",", ":"), sort_keys=True
                    ),
                }
            )


def compare(expected: Path, actual: Path) -> list[str]:
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
        if not files_equal(expected / path, actual / path):
            errors.append(f"generated file differs: {path}")
    return errors


def files_equal(left: Path, right: Path) -> bool:
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "data" / "generated" / SCHEMA,
    )
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output = args.output_dir.resolve()
    generated_root = (
        Path(__file__).resolve().parents[2] / "data" / "generated"
    ).resolve()
    if (
        args.output_dir.is_symlink()
        or output == generated_root
        or not output.is_relative_to(generated_root)
        or (output.exists() and not output.is_dir())
    ):
        raise ValueError("output directory must be a directory under data/generated")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="z-xml-dtd-", dir=output.parent) as name:
        temporary = Path(name)
        build(temporary)
        if args.check:
            if not output.is_dir():
                raise ValueError(f"missing generated corpus: {output}")
            errors = compare(temporary, output)
            if errors:
                raise ValueError("\n".join(errors))
            print(f"verified DTD corpus at {output}")
            return 0
        if output.exists():
            shutil.rmtree(output)
        temporary.replace(output)
    print(f"generated DTD corpus at {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(error)
        raise SystemExit(1) from error
