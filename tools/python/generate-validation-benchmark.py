#!/usr/bin/env python3
"""Generate deterministic fresh DTD-validation workloads and exact results."""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

SCHEMA = "z-xml-validation-generated-v1"
MODEL_BYTES = 64 * 1024 * 1024
IDENTITY_BYTES = 16 * 1024 * 1024
EXTERNAL_BYTES = 64 * 1024 * 1024
INVALID_BYTES = 64 * 1024
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
    target: str
    arguments: tuple[str, ...]
    expected_status: int
    stats: Stats
    content: str | None
    validity: str | None
    findings: tuple[Finding, ...] = ()
    id_count: int = 0
    idref_count: int = 0
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
        "event_checksum": f"{case.stats.checksum:016x}",
        "content": case.content,
        "validity": case.validity,
        "findings": len(case.findings),
        "findings_checksum": finding_checksum(case.findings),
        "first_finding": case.findings[0].code if case.findings else None,
        "first_finding_source_id": (
            case.findings[0].primary.source_id if case.findings else None
        ),
        "first_finding_offset": (
            case.findings[0].primary.offset if case.findings else None
        ),
        "last_finding": case.findings[-1].code if case.findings else None,
        "last_finding_source_id": (
            case.findings[-1].primary.source_id if case.findings else None
        ),
        "last_finding_offset": (
            case.findings[-1].primary.offset if case.findings else None
        ),
        "id_count": case.id_count,
        "idref_count": case.idref_count,
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


def generate_models(path: Path) -> Stats:
    prefix = (
        b"<!DOCTYPE root [<!ELEMENT root (item*)><!ELEMENT item (left,right?)>"
        b"<!ELEMENT left (#PCDATA)><!ELEMENT right (#PCDATA)>]><root>"
    )
    record = b"<item><left>x</left><right>y</right></item>"
    suffix = b"</root>"
    available = MODEL_BYTES - len(prefix) - len(suffix)
    count, filler = divmod(available, len(record))
    stats = Stats()
    stats.start(b"root")
    with path.open("wb") as stream:
        stream.write(prefix)
        write_repeated(stream, record, count)
        for _ in range(count):
            stats.start(b"item")
            stats.start(b"left")
            stats.text(b"x")
            stats.end(b"left")
            stats.start(b"right")
            stats.text(b"y")
            stats.end(b"right")
            stats.end(b"item")
        if filler:
            value = b" " * filler
            stream.write(value)
            stats.text(value)
        stream.write(suffix)
    stats.end(b"root")
    return stats


def generate_identities(path: Path) -> tuple[Stats, int]:
    prefix = (
        b"<!DOCTYPE root [<!ELEMENT root (item*)><!ELEMENT item EMPTY>"
        b"<!ATTLIST item id ID #REQUIRED ref IDREF #IMPLIED>]><root>"
    )
    suffix = b"</root>"
    sample = b'<item id="i0000000000" ref="i0000000000"/>'
    available = IDENTITY_BYTES - len(prefix) - len(suffix)
    count, filler = divmod(available, len(sample))
    stats = Stats()
    stats.start(b"root")
    with path.open("wb") as stream:
        stream.write(prefix)
        for index in range(count):
            value = f"i{index:010d}".encode()
            record = b'<item id="' + value + b'" ref="' + value + b'"/>'
            stream.write(record)
            stats.start(b"item", ((b"id", value, True), (b"ref", value, True)))
            stats.end(b"item")
        if filler:
            value = b" " * filler
            stream.write(value)
            stats.text(value)
        stream.write(suffix)
    stats.end(b"root")
    return stats, count


def generate_external(path: Path) -> tuple[Stats, bytes, bytes, bytes]:
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
    record = b"<item>" + b"x" * 224 + b"</item>"
    suffix = b"</root>"
    available = EXTERNAL_BYTES - len(prefix) - len(suffix)
    count, filler = divmod(available, len(record))
    stats = Stats()
    stats.start(b"root")
    stats.text(entity)
    with path.open("wb") as stream:
        stream.write(prefix)
        write_repeated(stream, record, count)
        for _ in range(count):
            stats.start(b"item", ((b"kind", b"external-default", False),))
            stats.text(record[6:-7])
            stats.end(b"item")
        if filler:
            value = b"x" * filler
            stream.write(value)
            stats.text(value)
        stream.write(suffix)
    stats.end(b"root")
    return stats, subset, declarations, entity


def generate_invalid(path: Path) -> tuple[Stats, int, tuple[Finding, ...]]:
    prefix = (
        b"<!DOCTYPE root [<!ELEMENT root (item*,child)><!ELEMENT item EMPTY>"
        b"<!ELEMENT child EMPTY>"
        b"<!ATTLIST item id ID #REQUIRED ref IDREF #IMPLIED>]><root>"
    )
    suffix = b"</root>"
    missing = b"<item/>"
    duplicate = b'<item id="dup"/><item id="dup" ref="missing"/>'
    sample = b'<item id="i000000"/>'
    available = (
        INVALID_BYTES - len(prefix) - len(missing) - len(duplicate) - len(suffix)
    )
    count, filler = divmod(available, len(sample))
    missing_offset = len(prefix) + count * len(sample)
    first_duplicate_offset = missing_offset + len(missing)
    second_duplicate_offset = first_duplicate_offset + len(b'<item id="dup"/>')
    findings = (
        Finding(
            "validity_required_attribute",
            Location(0, missing_offset),
            Location(0, prefix.index(b"id ID")),
        ),
        Finding("validity_duplicate_id", Location(0, second_duplicate_offset + 6)),
        Finding("validity_element_content", Location(0, INVALID_BYTES - len(suffix))),
        Finding("validity_unresolved_idref", Location(0, second_duplicate_offset + 15)),
    )
    stats = Stats()
    stats.start(b"root")
    with path.open("wb") as stream:
        stream.write(prefix)
        for index in range(count):
            value = f"i{index:06d}".encode()
            stream.write(b'<item id="' + value + b'"/>')
            stats.start(b"item", ((b"id", value, True),))
            stats.end(b"item")
        stream.write(missing)
        stats.start(b"item")
        stats.end(b"item")
        stream.write(duplicate)
        stats.start(b"item", ((b"id", b"dup", True),))
        stats.end(b"item")
        stats.start(
            b"item",
            ((b"id", b"dup", True), (b"ref", b"missing", True)),
        )
        stats.end(b"item")
        if filler:
            value = b" " * filler
            stream.write(value)
            stats.text(value)
        stream.write(suffix)
    stats.end(b"root")
    return stats, count, findings


def write_file(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def build(output: Path) -> None:
    valid = output / "valid"
    invalid = output / "invalid"
    valid.mkdir(parents=True)
    invalid.mkdir(parents=True)

    models_path = valid / "models-64m.xml"
    models_stats = generate_models(models_path)
    identities_path = valid / "identities-16m.xml"
    identities_stats, identity_count = generate_identities(identities_path)
    external_path = valid / "external-64m.xml"
    external_stats, subset, declarations, entity = generate_external(external_path)
    subset_path = valid / "external.dtd"
    declarations_path = valid / "declarations.ent"
    entity_path = valid / "value.ent"
    write_file(subset_path, subset)
    write_file(declarations_path, declarations)
    write_file(entity_path, entity)
    external_resources = (subset_path, declarations_path, entity_path)

    invalid_path = invalid / "findings-64k.xml"
    invalid_stats, repeated_identity_count, invalid_findings = generate_invalid(
        invalid_path
    )
    nondeterministic_input = (
        b"<!DOCTYPE root [<!ELEMENT root (item|item)>"
        b"<!ELEMENT item EMPTY>]><root><item/></root>"
    )
    nondeterministic_path = invalid / "nondeterministic.xml"
    write_file(nondeterministic_path, nondeterministic_input)
    nondeterministic_stats = Stats()
    nondeterministic_stats.start(b"root")
    nondeterministic_stats.start(b"item")
    nondeterministic_stats.end(b"item")
    nondeterministic_stats.end(b"root")

    syntax_prefix = b"<!DOCTYPE root [<!--"
    syntax_suffix = b"--><!ELEMENT root (a|)>]><root/>"
    syntax_input = syntax_prefix + b"x" * (
        INVALID_BYTES - len(syntax_prefix) - len(syntax_suffix)
    )
    syntax_input += syntax_suffix
    syntax_path = invalid / "syntax-64k.xml"
    write_file(syntax_path, syntax_input)
    unavailable_input = b"<!DOCTYPE root SYSTEM 'missing.dtd'><root/>"
    unavailable_path = invalid / "external-unavailable.xml"
    write_file(unavailable_path, unavailable_input)
    limit_input = (
        b"<!DOCTYPE root [<!ELEMENT root (a,b)><!ELEMENT a EMPTY>"
        b"<!ELEMENT b EMPTY>]><root><a/><b/></root>"
    )
    limit_path = invalid / "content-position-limit.xml"
    write_file(limit_path, limit_input)

    internal = "z-xml-validation-internal"
    external_target = "z-xml-validation-external"
    cases = [
        Case(
            "models-64m",
            models_path,
            "benchmark-valid",
            internal,
            (),
            0,
            models_stats,
            "complete",
            "valid",
        ),
        Case(
            "identities-16m",
            identities_path,
            "benchmark-valid",
            internal,
            (),
            0,
            identities_stats,
            "complete",
            "valid",
            id_count=identity_count,
            idref_count=identity_count,
        ),
        Case(
            "external-64m",
            external_path,
            "benchmark-valid",
            external_target,
            (),
            0,
            external_stats,
            "complete",
            "valid",
            sources=SourceStats(
                resolver_calls=3,
                resolved_sources=3,
                closed_sources=3,
                external_subset_sources=1,
                parameter_entity_sources=1,
                general_entity_sources=1,
                source_bytes=sum(path.stat().st_size for path in external_resources),
            ),
            resources=external_resources,
        ),
        Case(
            "findings-64k",
            invalid_path,
            "benchmark-valid",
            internal,
            (),
            0,
            invalid_stats,
            "complete",
            "invalid",
            invalid_findings,
            id_count=repeated_identity_count + 1,
            idref_count=1,
        ),
        Case(
            "nondeterministic",
            nondeterministic_path,
            "benchmark-valid",
            internal,
            (),
            0,
            nondeterministic_stats,
            "complete",
            "invalid",
            (
                Finding(
                    "validity_nondeterministic_content_model",
                    Location(0, nondeterministic_input.index(b"<!ELEMENT")),
                ),
            ),
        ),
        Case(
            "syntax-64k",
            syntax_path,
            "not-well-formed",
            internal,
            (),
            2,
            Stats(),
            None,
            None,
            failure=Failure(
                "InvalidXml",
                "malformed_element_declaration",
                0,
                syntax_input.index(b")"),
            ),
        ),
        Case(
            "external-unavailable",
            unavailable_path,
            "benchmark-valid",
            external_target,
            ("--external=unavailable",),
            1,
            Stats(),
            None,
            None,
            sources=SourceStats(resolver_calls=1, unavailable_results=1),
            failure=Failure(
                "ExternalResourceUnavailable",
                "resolver_not_found",
                0,
                unavailable_input.index(b"DOCTYPE") + len(b"DOCTYPE"),
            ),
        ),
        Case(
            "content-position-limit",
            limit_path,
            "benchmark-valid",
            internal,
            ("--max-validation-content-positions=1",),
            3,
            Stats(),
            None,
            None,
            failure=Failure(
                "LimitExceeded",
                "validation_content_position_limit",
                0,
                limit_input.index(b"<root>"),
            ),
        ),
    ]

    if identity_count <= 0 or repeated_identity_count <= 0:
        raise ValueError("identity workloads need at least one generated record")

    with (output / "manifest.tsv").open("w", encoding="utf-8", newline="") as stream:
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
                    "targets": case.target,
                    "program_args": " ".join(case.arguments) or "-",
                    "expected_status": case.expected_status,
                    "expected_result": json.dumps(
                        result(case), separators=(",", ":"), sort_keys=True
                    ),
                }
            )


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
    with tempfile.TemporaryDirectory(
        prefix="z-xml-validation-", dir=output.parent
    ) as name:
        temporary = Path(name)
        build(temporary)
        if args.check:
            if not output.is_dir():
                raise ValueError(f"missing generated corpus: {output}")
            errors = compare(temporary, output)
            if errors:
                raise ValueError("\n".join(errors))
            print(f"verified validation corpus at {output}")
            return 0
        if output.exists():
            shutil.rmtree(output)
        temporary.replace(output)
    print(f"generated validation corpus at {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(error)
        raise SystemExit(1) from error
