#!/usr/bin/env python3
"""Classify declared XML processors against the pinned W3C XML Test Suite."""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

XML_BASE = "{http://www.w3.org/XML/1998/namespace}base"
RESULT_SCHEMA = "z-xml-w3c-results-v1"
TARGET_SCHEMAS = {"z-xml-targets-v1", "z-xml-targets-v2"}
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
KNOWN_PROCESSOR_CLASSES = {
    "wf",
    "validating",
    "partial",
    "subset",
    "lexical",
    "index",
}
WORK_LANES = {
    "event",
    "dom",
    "partial-dom",
    "subset",
    "lexical",
    "structural-index",
    "validated",
}
INPUT_MODELS = {"streaming-reader", "file-reader", "whole-file"}
CASE_TYPES = {"valid", "invalid", "not-wf", "error"}
ENTITY_MODES = {"none", "general", "parameter", "both"}
XML_VERSIONS = {"1.0", "1.1"}
XML_EDITIONS = {"1", "2", "3", "4", "5"}
NAMESPACE_MODES = {"yes", "no"}
RECOMMENDATION_VERSIONS = {
    "XML1.0": "1.0",
    "XML1.1": "1.1",
    "NS1.0": "1.0",
    "NS1.1": "1.1",
    "XML1.0-errata2e": "1.0",
    "XML1.0-errata3e": "1.0",
    "XML1.0-errata4e": "1.0",
    "NS1.0-errata1e": "1.0",
}
SKIP_EXPECTATIONS = {"unsupported-feature", "out-of-profile", "optional"}
EXPECTED_MANIFESTS = 21
EXPECTED_CASES = 2585
MAX_TARGET_BYTES = 1024 * 1024
MAX_CATALOG_BYTES = 1024 * 1024
MAX_CASE_BYTES = 16 * 1024 * 1024
ENTITY_DECLARATION = re.compile(
    r"<!ENTITY\s+([A-Za-z_:][\w.:-]*)\s+SYSTEM\s+['\"]([^'\"]+)['\"]\s*>"
)
SYSTEM_IDENTIFIER = re.compile(
    r"(?:SYSTEM\s+|PUBLIC\s+['\"][^'\"]*['\"]\s+)['\"]([^'\"]+)['\"]",
    re.IGNORECASE,
)
XML_DECLARATION = re.compile(rb"^\s*<\?xml[^?]*\?>")
RESULT_FIELDS = [
    "target",
    "work_lane",
    "input_model",
    "test_id",
    "manifest",
    "type",
    "entities",
    "version",
    "edition",
    "namespace",
    "encoding",
    "expected",
    "observed",
    "verdict",
    "reason",
    "uri",
    "sections",
]


@dataclass(frozen=True)
class Target:
    name: str
    executable: Path
    processor_class: str
    features: frozenset[str]
    work_lane: str
    input_model: str


@dataclass(frozen=True)
class Case:
    test_id: str
    manifest: Path
    input_path: Path
    case_type: str
    entities: str
    version: str
    edition: str
    recommendation_version: str
    namespace: str
    sections: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--address-space-mib", type=int, default=2048)
    parser.add_argument("--cpu-seconds", type=int, default=5)
    parser.add_argument("--open-files", type=int, default=64)
    return parser.parse_args()


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def read_limited(path: Path, limit: int) -> bytes:
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{path}: exceeds the {limit}-byte protocol limit")
    return data


def result_path(args: argparse.Namespace, suite: Path, bin_dir: Path) -> Path:
    resolved = args.results.resolve()
    targets = args.targets.resolve()
    if (
        args.results.is_symlink()
        or resolved == targets
        or resolved.is_relative_to(suite)
        or resolved.is_relative_to(bin_dir)
    ):
        raise ValueError("result path overlaps a conformance input")
    if resolved.exists() and not resolved.is_file():
        raise ValueError(f"result path is not a regular file: {resolved}")
    return resolved


def read_targets(path: Path, bin_dir: Path, selected: set[str]) -> list[Target]:
    lines = read_limited(path, MAX_TARGET_BYTES).decode("utf-8").splitlines()
    if len(lines) < 3:
        raise ValueError(f"{path}: empty target manifest")
    schema = lines[0].removeprefix("#").strip()
    if schema not in TARGET_SCHEMAS:
        raise ValueError(f"{path}: unsupported target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{path}: invalid target header")

    root = bin_dir.resolve()
    targets: list[Target] = []
    seen: set[str] = set()
    selected_profiles: dict[str, tuple[str, str]] = {}
    for line_number, line in enumerate(lines[2:], 3):
        if not line.strip():
            continue
        if line.startswith("#"):
            raise ValueError(f"{path}:{line_number}: unexpected comment")
        fields = line.split("\t")
        if len(fields) != 6 or any(not field for field in fields):
            raise ValueError(f"{path}:{line_number}: invalid target row")
        name, executable, processor_class, features_text, work_lane, input_model = (
            fields
        )
        if name in seen:
            raise ValueError(f"{path}:{line_number}: duplicate target {name}")
        seen.add(name)
        features = features_text.split(",")
        if any(not feature for feature in features) or len(features) != len(
            set(features)
        ):
            raise ValueError(f"{path}:{line_number}: invalid target features")
        if (
            processor_class not in KNOWN_PROCESSOR_CLASSES
            or work_lane not in WORK_LANES
            or input_model not in INPUT_MODELS
        ):
            raise ValueError(f"{path}:{line_number}: invalid target declaration")
        if processor_class == "wf" and work_lane != "event":
            raise ValueError(f"{path}:{line_number}: {name}: wf requires event lane")
        if processor_class == "validating" and work_lane != "validated":
            raise ValueError(
                f"{path}:{line_number}: {name}: validating requires validated lane"
            )
        supports_profile = processor_class in {"wf", "validating"} or (
            processor_class == "partial" and work_lane == "validated"
        )
        if selected and name in selected:
            selected_profiles[name] = (processor_class, work_lane)
        if selected and name not in selected:
            continue
        if not supports_profile:
            continue
        program = (root / executable).resolve()
        try:
            program.relative_to(root)
        except ValueError as error:
            raise ValueError(
                f"{name}: executable escapes the binary directory"
            ) from error
        targets.append(
            Target(
                name=name,
                executable=program,
                processor_class=processor_class,
                features=frozenset(features),
                work_lane=work_lane,
                input_model=input_model,
            )
        )
    unknown = selected.difference(seen)
    if unknown:
        raise ValueError("unknown targets: " + ",".join(sorted(unknown)))
    unsupported = {
        name: profile
        for name, profile in selected_profiles.items()
        if not (
            profile[0] in {"wf", "validating"}
            or (profile[0] == "partial" and profile[1] == "validated")
        )
    }
    if unsupported:
        details = ",".join(
            f"{name}:{profile[0]}:{profile[1]}"
            for name, profile in sorted(unsupported.items())
        )
        raise ValueError(f"targets do not declare a W3C processor profile: {details}")
    if not targets:
        raise ValueError(f"{path}: no W3C processor targets selected")
    return targets


def read_catalog_manifests(suite: Path) -> list[Path]:
    catalog = suite / "xmlconf.xml"
    text = read_limited(catalog, MAX_CATALOG_BYTES).decode("utf-8")
    if "<TESTSUITE" not in text:
        raise ValueError(f"{catalog}: missing TESTSUITE root")
    declarations = ENTITY_DECLARATION.findall(text)
    if len(declarations) != EXPECTED_MANIFESTS:
        raise ValueError(
            f"{catalog}: expected {EXPECTED_MANIFESTS} manifests, got {len(declarations)}"
        )

    manifests: list[Path] = []
    names: set[str] = set()
    paths: set[Path] = set()
    for name, uri in declarations:
        if name in names:
            raise ValueError(f"{catalog}: duplicate manifest entity {name}")
        names.add(name)
        if text.count(f"&{name};") != 1:
            raise ValueError(f"{catalog}: manifest entity {name} is not used once")
        manifest = (suite / uri).resolve()
        try:
            manifest.relative_to(suite)
        except ValueError as error:
            raise ValueError(
                f"{catalog}: manifest path escapes suite: {uri}"
            ) from error
        if manifest in paths:
            raise ValueError(f"{catalog}: duplicate manifest path {uri}")
        paths.add(manifest)
        if not manifest.is_file():
            raise ValueError(f"{catalog}: missing manifest {uri}")
        manifests.append(manifest)
    return manifests


def parse_manifest(path: Path) -> ET.Element:
    data = read_limited(path, MAX_CATALOG_BYTES)
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        body = XML_DECLARATION.sub(b"", data, count=1)
        try:
            root = ET.fromstring(b"<TESTCASES>" + body + b"</TESTCASES>")
        except ET.ParseError as error:
            raise ValueError(f"{path}: invalid catalog manifest: {error}") from error
    if local_name(root.tag) not in {"TEST", "TESTCASES", "TESTSUITE"}:
        raise ValueError(f"{path}: invalid catalog root {local_name(root.tag)}")
    return root


def iter_tests(element: ET.Element, base: Path):
    next_base = base
    if XML_BASE in element.attrib:
        next_base = next_base / element.attrib[XML_BASE]
    if local_name(element.tag) == "TEST":
        yield element, next_base
        return
    for child in element:
        yield from iter_tests(child, next_base)


def read_cases(suite: Path) -> list[Case]:
    cases: list[Case] = []
    seen_ids: set[str] = set()
    for manifest in read_catalog_manifests(suite):
        root = parse_manifest(manifest)
        for element, base in iter_tests(root, manifest.parent):
            uri = element.get("URI")
            test_id = element.get("ID")
            case_type = element.get("TYPE")
            sections = element.get("SECTIONS")
            if None in {uri, test_id, case_type, sections}:
                raise ValueError(
                    f"{manifest}: TEST is missing ID, TYPE, URI, or SECTIONS"
                )
            if not uri or not test_id:
                raise ValueError(f"{manifest}: TEST has an empty ID or URI")
            if test_id in seen_ids:
                raise ValueError(f"{manifest}: duplicate test ID {test_id}")
            seen_ids.add(test_id)
            entities = element.get("ENTITIES", "none")
            version_values = element.get("VERSION")
            versions = version_values.split() if version_values else []
            edition_values = element.get("EDITION")
            editions = edition_values.split() if edition_values else []
            recommendation = element.get("RECOMMENDATION", "XML1.0")
            namespace = element.get("NAMESPACE", "yes")
            if case_type not in CASE_TYPES:
                raise ValueError(f"{manifest}: {test_id}: unknown TYPE {case_type}")
            if entities not in ENTITY_MODES:
                raise ValueError(f"{manifest}: {test_id}: unknown ENTITIES {entities}")
            if versions and any(version not in XML_VERSIONS for version in versions):
                raise ValueError(f"{manifest}: {test_id}: unknown VERSION")
            if editions and any(edition not in XML_EDITIONS for edition in editions):
                raise ValueError(f"{manifest}: {test_id}: unknown EDITION")
            if recommendation not in RECOMMENDATION_VERSIONS:
                raise ValueError(
                    f"{manifest}: {test_id}: unknown RECOMMENDATION {recommendation}"
                )
            if namespace not in NAMESPACE_MODES:
                raise ValueError(
                    f"{manifest}: {test_id}: unknown NAMESPACE {namespace}"
                )
            input_path = (base / uri).resolve()
            try:
                input_path.relative_to(suite)
            except ValueError as error:
                raise ValueError(
                    f"{manifest}: test path escapes suite: {uri}"
                ) from error
            cases.append(
                Case(
                    test_id=test_id,
                    manifest=manifest,
                    input_path=input_path,
                    case_type=case_type,
                    entities=entities,
                    version=" ".join(versions) if versions else "all",
                    edition=" ".join(editions) if editions else "all",
                    recommendation_version=RECOMMENDATION_VERSIONS[recommendation],
                    namespace=namespace,
                    sections=sections,
                )
            )
    if len(cases) != EXPECTED_CASES:
        raise ValueError(
            f"catalog discovery expected {EXPECTED_CASES} cases, got {len(cases)}"
        )
    return cases


def input_encoding(data: bytes) -> str:
    sample = data[:512]
    if sample.startswith((b"\x00\x00\xfe\xff", b"\xff\xfe\x00\x00")):
        return "utf32"
    if sample.startswith((b"\xfe\xff", b"\xff\xfe")):
        return "utf16"
    if sample.startswith((b"\x00\x00\x00\x3c", b"\x3c\x00\x00\x00")):
        return "utf32"
    if sample.startswith((b"\x00\x3c\x00\x3f", b"\x3c\x00\x3f\x00")):
        return "utf16"
    declaration = sample[3:] if sample.startswith(b"\xef\xbb\xbf") else sample
    for encoding in ("ascii", "utf-16", "utf-32"):
        try:
            decoded = sample.decode(encoding)
        except UnicodeError:
            continue
        if "<?xml" in decoded:
            declaration = decoded.encode("ascii", errors="ignore")
            break
    match = re.search(
        rb"encoding\s*=\s*['\"]([^'\"]+)['\"]", declaration, re.IGNORECASE
    )
    if match is None:
        return "utf8"
    declared = re.sub(rb"[^a-z0-9]", b"", match.group(1).lower()).decode("ascii")
    if declared == "utf8":
        return "utf8"
    if declared in {"utf16", "iso10646ucs2"}:
        return "utf16"
    if declared in {"utf32", "iso10646ucs4"}:
        return "utf32"
    if declared in {"iso88591", "latin1"}:
        return "latin1"
    if declared in {"usascii", "ascii"}:
        return "ascii"
    return "legacy_encodings"


def document_text(data: bytes, encoding: str) -> str:
    codec = {"utf16": "utf-16", "utf32": "utf-32"}.get(encoding)
    if codec is None:
        return data.decode("latin-1")
    try:
        return data.decode(codec)
    except UnicodeError:
        return ""


def doctype_text(text: str) -> str:
    start = text.find("<!DOCTYPE")
    if start < 0:
        return ""
    quote = ""
    subset_depth = 0
    for index in range(start + len("<!DOCTYPE"), len(text)):
        char = text[index]
        if quote:
            if char == quote:
                quote = ""
        elif char in {'"', "'"}:
            quote = char
        elif char == "[":
            subset_depth += 1
        elif char == "]" and subset_depth:
            subset_depth -= 1
        elif char == ">" and subset_depth == 0:
            return text[start : index + 1]
    return text[start:]


def case_versions(case: Case) -> set[str]:
    if case.version == "all":
        return XML_VERSIONS
    return set(case.version.split())


def supports_version(target: Target, version: str) -> bool:
    token = version.replace(".", "_")
    return f"xml_version_{token}" in target.features or any(
        feature.startswith(f"xml{token}_") and feature.endswith("e")
        for feature in target.features
    )


def requirements(
    target: Target, case: Case, encoding: str, text: str
) -> tuple[set[str], str | None]:
    versions = case_versions(case)
    if not any(supports_version(target, version) for version in versions):
        return set(), "xml-version"
    if case.case_type == "error":
        return set(), "optional-error"
    raw_names = "raw_names" in target.features
    if raw_names and case.namespace != "no":
        return set(), "namespace-processing-mode"
    if not raw_names and case.namespace == "no":
        return set(), "namespace-off-mode"

    needed = {"document", encoding}
    if not raw_names:
        needed.add("namespaces")
    doctype = doctype_text(text)
    if case.case_type == "invalid" or doctype:
        needed.add("dtd")
    if re.search(r"<!DOCTYPE\s+[^>]+\s+(?:SYSTEM|PUBLIC)\s", doctype):
        needed.add("external_dtd")
    if any(
        ".." in identifier.split("/")
        for identifier in SYSTEM_IDENTIFIER.findall(doctype)
    ):
        needed.add("external_parent_paths")
    if case.entities in {"general", "both"}:
        needed.add("external_general_entities")
    if case.entities in {"parameter", "both"}:
        needed.add("external_parameter_entities")
    return needed, None


def expectation(
    target: Target, case: Case, encoding: str, text: str
) -> tuple[str, str]:
    edition_versions = case_versions(case)
    if case.version == "all" and case.edition != "all":
        edition_versions = {case.recommendation_version}
    if case.edition != "all" and not any(
        f"xml{version.replace('.', '_')}_{edition}e" in target.features
        for version in edition_versions
        for edition in case.edition.split()
    ):
        return "out-of-profile", "xml-edition"
    if (
        target.processor_class == "partial"
        and target.work_lane == "validated"
        and case.case_type != "valid"
    ):
        return "out-of-profile", "partial-validation"
    needed, reason = requirements(target, case, encoding, text)
    if reason is not None:
        if reason == "optional-error":
            return "optional", reason
        return "out-of-profile", reason
    if target.work_lane == "validated" and "dtd" not in needed:
        return "out-of-profile", "validating-adapter-requires-dtd"
    missing = needed.difference(target.features)
    if missing:
        return "unsupported-feature", "missing:" + ",".join(sorted(missing))
    if case.case_type == "invalid":
        expected = "reject" if target.work_lane == "validated" else "accept"
        return expected, ""
    if case.case_type == "not-wf":
        return "reject", ""
    return "accept", ""


def target_issue(target: Target) -> str | None:
    if not target.executable.is_file():
        return "missing-executable"
    if not os.access(target.executable, os.X_OK):
        return "executable-not-runnable"
    return None


def observe(
    target: Target, case: Case, args: argparse.Namespace
) -> tuple[str, str, str]:
    command = [
        "prlimit",
        f"--as={args.address_space_mib * 1024 * 1024}",
        f"--cpu={args.cpu_seconds}",
        f"--nofile={args.open_files}",
        "--",
        str(target.executable),
        str(case.input_path),
    ]
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=args.timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return "timeout", "timeout", "timeout"
    except OSError:
        return "not-run", "tool-error", "process-start"
    if completed.returncode == 0:
        return "accept", "", ""
    if completed.returncode == 2:
        return "reject", "", ""
    if completed.returncode < 0:
        return f"signal:{-completed.returncode}", "tool-error", "adapter-signal"
    return f"exit:{completed.returncode}", "tool-error", "adapter-exit"


def case_input(case: Case) -> tuple[bytes | None, str, str]:
    if not case.input_path.is_file():
        return None, "missing", "missing-input"
    try:
        data = read_limited(case.input_path, MAX_CASE_BYTES)
    except ValueError:
        return None, "too-large", "input-too-large"
    except OSError:
        return None, "unreadable", "input-read"
    return data, input_encoding(data), ""


def write_row(
    writer: csv.DictWriter,
    suite: Path,
    target: Target,
    case: Case,
    encoding: str,
    expected: str,
    observed: str,
    verdict: str,
    reason: str,
) -> None:
    writer.writerow(
        {
            "target": target.name,
            "work_lane": target.work_lane,
            "input_model": target.input_model,
            "test_id": case.test_id,
            "manifest": case.manifest.relative_to(suite),
            "type": case.case_type,
            "entities": case.entities,
            "version": case.version,
            "edition": case.edition,
            "namespace": case.namespace,
            "encoding": encoding,
            "expected": expected,
            "observed": observed,
            "verdict": verdict,
            "reason": reason,
            "uri": case.input_path.relative_to(suite),
            "sections": case.sections,
        }
    )


def check_limits(args: argparse.Namespace) -> None:
    if (
        args.address_space_mib <= 0
        or args.cpu_seconds <= 0
        or args.open_files <= 0
        or not math.isfinite(args.timeout)
        or args.timeout <= 0
    ):
        raise ValueError("resource limits and timeout must be positive and finite")
    if shutil.which("prlimit") is None:
        raise ValueError("W3C runner requires prlimit from util-linux")
    try:
        probe = subprocess.run(
            [
                "prlimit",
                f"--as={args.address_space_mib * 1024 * 1024}",
                f"--cpu={args.cpu_seconds}",
                f"--nofile={args.open_files}",
                "--",
                "true",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError as error:
        raise ValueError("could not start the W3C process-limit probe") from error
    if probe.returncode != 0:
        raise ValueError("could not apply configured W3C process limits")


def main() -> int:
    args = parse_args()
    suite = args.suite.resolve()
    bin_dir = args.bin_dir.resolve()
    try:
        results = result_path(args, suite, bin_dir)
        results.parent.mkdir(parents=True, exist_ok=True)
        results.unlink(missing_ok=True)
        check_limits(args)
        if not suite.is_dir():
            raise ValueError(f"W3C suite not found at {suite}")
        if not args.targets.resolve().is_file():
            raise ValueError(f"target manifest not found: {args.targets.resolve()}")
        if not bin_dir.is_dir():
            raise ValueError(f"binary directory not found: {bin_dir}")
        targets = read_targets(args.targets, bin_dir, set(args.target))
        cases = read_cases(suite)
    except (OSError, UnicodeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    totals: Counter[str] = Counter()
    skip_reasons: Counter[str] = Counter()
    failure_reasons: Counter[str] = Counter()
    no_applicable: list[str] = []
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            newline="",
            dir=results.parent,
            prefix=results.name + ".",
            suffix=".tmp",
            delete=False,
        ) as stream:
            temporary_path = Path(stream.name)
            stream.write(f"# {RESULT_SCHEMA}\n")
            writer = csv.DictWriter(stream, fieldnames=RESULT_FIELDS, delimiter="\t")
            writer.writeheader()
            for target in targets:
                counts: Counter[str] = Counter()
                issue = target_issue(target)
                for case in cases:
                    data, encoding, input_reason = case_input(case)
                    if data is None:
                        expected = "unknown"
                        observed = "not-run"
                        verdict = "fail"
                        reason = input_reason
                    else:
                        expected, reason = expectation(
                            target, case, encoding, document_text(data, encoding)
                        )
                        if expected in SKIP_EXPECTATIONS:
                            observed = "not-run"
                            verdict = "skip"
                        elif issue is not None:
                            observed = "not-run"
                            verdict = "tool-error"
                            reason = issue
                        else:
                            observed, process_verdict, process_reason = observe(
                                target, case, args
                            )
                            if process_verdict:
                                verdict = process_verdict
                                reason = process_reason
                            elif observed == expected:
                                verdict = "pass"
                            else:
                                verdict = "mismatch"
                                reason = f"expected-{expected}"
                    counts[verdict] += 1
                    totals[verdict] += 1
                    if verdict == "skip":
                        if not reason:
                            raise ValueError(
                                f"{target.name}: {case.test_id}: skip has no reason"
                            )
                        skip_reasons[f"{expected}:{reason}"] += 1
                    elif verdict != "pass":
                        failure_reasons[f"{verdict}:{reason}"] += 1
                    write_row(
                        writer,
                        suite,
                        target,
                        case,
                        encoding,
                        expected,
                        observed,
                        verdict,
                        reason,
                    )
                applicable = sum(
                    counts[name]
                    for name in (
                        "pass",
                        "fail",
                        "mismatch",
                        "timeout",
                        "tool-error",
                    )
                )
                if applicable == 0:
                    no_applicable.append(target.name)
                print(
                    f"{target.name:<24} applicable={applicable:<4} "
                    f"pass={counts['pass']:<4} fail={counts['fail']:<3} "
                    f"skip={counts['skip']:<4} mismatch={counts['mismatch']:<3} "
                    f"timeout={counts['timeout']:<3} tool-error={counts['tool-error']:<3}"
                )
        temporary_path.replace(results)
        temporary_path = None
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)

    print(
        f"catalog={len(cases)} pass={totals['pass']} fail={totals['fail']} "
        f"skip={totals['skip']} mismatch={totals['mismatch']} "
        f"timeout={totals['timeout']} tool-error={totals['tool-error']}"
    )
    for reason, count in sorted(skip_reasons.items()):
        print(f"skip {reason}: {count}")
    for reason, count in sorted(failure_reasons.items()):
        print(f"failure {reason}: {count}", file=sys.stderr)
    if no_applicable:
        print(
            "targets with no applicable W3C cases: " + ",".join(no_applicable),
            file=sys.stderr,
        )
    print(f"results: {results}")
    failed = any(totals[name] for name in ("fail", "mismatch", "timeout", "tool-error"))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
