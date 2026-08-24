#!/usr/bin/env python3
"""Run capable reference adapters against the W3C XML Test Suite catalog."""

from __future__ import annotations

import argparse
import csv
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

XML_BASE = "{http://www.w3.org/XML/1998/namespace}base"
MANIFEST_ROOTS = {"TESTCASES", "TESTSUITE"}
SUPPORTED_PROCESSOR_CLASSES = {"wf", "validating"}
KNOWN_PROCESSOR_CLASSES = SUPPORTED_PROCESSOR_CLASSES | {
    "partial",
    "subset",
    "lexical",
    "index",
}
TARGET_SCHEMAS = {"z-xml-targets-v1", "z-xml-targets-v2"}
NON_APPLICABLE_VERDICTS = {"unsupported-feature", "out-of-profile", "optional"}
CASE_TYPES = {"valid", "invalid", "not-wf", "error"}
ENTITY_MODES = {"none", "general", "parameter", "both"}
XML_VERSIONS = {"1.0", "1.1"}
XML_EDITIONS = {"1", "2", "3", "4", "5"}
NAMESPACE_MODES = {"yes", "no"}


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
    namespace: str
    sections: str


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def read_targets(path: Path, bin_dir: Path, selected: set[str]) -> list[Target]:
    targets: list[Target] = []
    seen: set[str] = set()
    with path.open(newline="", encoding="utf-8") as stream:
        lines = list(stream)
        comments = {line[1:].strip() for line in lines if line.startswith("#")}
        if not TARGET_SCHEMAS.intersection(comments):
            raise ValueError(f"{path}: unsupported target schema")
        for row in csv.reader(lines, delimiter="\t"):
            if not row or row[0].startswith("#"):
                continue
            if len(row) != 6:
                raise ValueError(f"{path}: expected 6 fields, got {len(row)}")
            name, executable, processor_class, features, work_lane, input_model = row
            feature_list = features.split(",")
            if not name or name in seen:
                raise ValueError(f"{path}: duplicate or empty target name {name}")
            if processor_class not in KNOWN_PROCESSOR_CLASSES:
                raise ValueError(f"{path}: {name}: unknown processor class")
            if (
                not executable
                or not work_lane
                or not input_model
                or any(not feature for feature in feature_list)
                or len(feature_list) != len(set(feature_list))
            ):
                raise ValueError(f"{path}: {name}: invalid target fields")
            seen.add(name)
            if selected and name not in selected:
                continue
            targets.append(
                Target(
                    name=name,
                    executable=(bin_dir / executable).resolve(),
                    processor_class=processor_class,
                    features=frozenset(feature_list),
                    work_lane=work_lane,
                    input_model=input_model,
                )
            )
    missing = selected.difference(target.name for target in targets)
    if missing:
        raise ValueError(f"unknown target names: {', '.join(sorted(missing))}")
    return targets


def iter_tests(element: ET.Element, manifest: Path, base: Path):
    next_base = base
    if XML_BASE in element.attrib:
        next_base = next_base / element.attrib[XML_BASE]
    if local_name(element.tag) == "TEST":
        yield element, next_base
        return
    for child in element:
        yield from iter_tests(child, manifest, next_base)


def read_cases(suite: Path) -> list[Case]:
    suite = suite.resolve()
    cases: list[Case] = []
    seen: set[tuple[Path, str, str]] = set()
    for manifest in sorted(suite.rglob("*.xml")):
        try:
            root = ET.parse(manifest).getroot()
        except (ET.ParseError, OSError, ValueError):
            continue
        if local_name(root.tag) not in MANIFEST_ROOTS:
            continue
        for element, base in iter_tests(root, manifest, manifest.parent):
            uri = element.get("URI")
            test_id = element.get("ID")
            case_type = element.get("TYPE")
            if uri is None or test_id is None or case_type is None:
                raise ValueError(f"{manifest}: TEST is missing ID, TYPE, or URI")
            entities = element.get("ENTITIES", "none")
            versions = element.get("VERSION", "1.0").split()
            edition = element.get("EDITION", "unspecified")
            namespace = element.get("NAMESPACE", "yes")
            if case_type not in CASE_TYPES:
                raise ValueError(f"{manifest}: {test_id}: unknown TYPE {case_type}")
            if entities not in ENTITY_MODES:
                raise ValueError(f"{manifest}: {test_id}: unknown ENTITIES {entities}")
            if not versions or any(version not in XML_VERSIONS for version in versions):
                raise ValueError(f"{manifest}: {test_id}: unknown VERSION")
            if edition != "unspecified" and (
                not edition.split()
                or any(value not in XML_EDITIONS for value in edition.split())
            ):
                raise ValueError(f"{manifest}: {test_id}: unknown EDITION")
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
            key = (manifest.resolve(), test_id, uri)
            if key in seen:
                continue
            seen.add(key)
            cases.append(
                Case(
                    test_id=test_id,
                    manifest=manifest.resolve(),
                    input_path=input_path,
                    case_type=case_type,
                    entities=entities,
                    version=" ".join(versions),
                    edition=edition,
                    namespace=namespace,
                    sections=element.get("SECTIONS", ""),
                )
            )
    return cases


def input_encoding(path: Path) -> str:
    data = path.read_bytes()[:512]
    if data.startswith((b"\x00\x00\xfe\xff", b"\xff\xfe\x00\x00")):
        return "utf32"
    if data.startswith((b"\xfe\xff", b"\xff\xfe")):
        return "utf16"
    if data.startswith((b"\x00\x00\x00\x3c", b"\x3c\x00\x00\x00")):
        return "utf32"
    if data.startswith((b"\x00\x3c\x00\x3f", b"\x3c\x00\x3f\x00")):
        return "utf16"
    sample = data[3:] if data.startswith(b"\xef\xbb\xbf") else data
    for encoding in ("ascii", "utf-16", "utf-32"):
        try:
            decoded = data.decode(encoding)
        except UnicodeError:
            continue
        if "<?xml" in decoded:
            sample = decoded.encode("ascii", errors="ignore")
            break
    match = re.search(rb"encoding\s*=\s*['\"]([^'\"]+)['\"]", sample, re.IGNORECASE)
    if match is None:
        return "utf8"
    declared = re.sub(rb"[^a-z0-9]", b"", match.group(1).lower()).decode("ascii")
    if declared in {"utf8"}:
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


def document_text(path: Path, encoding: str) -> str:
    data = path.read_bytes()
    codec = {"utf16": "utf-16", "utf32": "utf-32"}.get(encoding)
    if codec is None:
        return data.decode("latin-1")
    try:
        return data.decode(codec)
    except UnicodeError:
        return ""


def requirements(target: Target, case: Case) -> tuple[set[str], str | None]:
    versions = case.version.split()
    if not any(
        f"xml_version_{version.replace('.', '_')}" in target.features
        for version in versions
    ):
        return set(), "xml-version"
    if case.case_type == "error":
        return set(), "optional-error"
    if case.case_type not in {"valid", "invalid", "not-wf"}:
        raise ValueError(f"unclassified W3C case type: {case.case_type}")
    raw_names = "raw_names" in target.features
    if raw_names and case.namespace != "no":
        return set(), "namespace-processing-mode"
    if not raw_names and case.namespace == "no":
        return set(), "namespace-off-mode"

    encoding = input_encoding(case.input_path)
    needed = {"document", encoding}
    if not raw_names:
        needed.add("namespaces")
    text = document_text(case.input_path, encoding)
    if case.case_type == "invalid" or "<!DOCTYPE" in text:
        needed.add("dtd")
    if re.search(r"<!DOCTYPE\s+[^>]+\s+(?:SYSTEM|PUBLIC)\s", text):
        needed.add("external_dtd")
    if case.entities in {"general", "both"}:
        needed.add("external_general_entities")
    if case.entities in {"parameter", "both"}:
        needed.add("external_parameter_entities")
    return needed, None


def expectation(target: Target, case: Case) -> tuple[str, str]:
    if target.processor_class not in SUPPORTED_PROCESSOR_CLASSES:
        return "out-of-profile", "processor-profile"
    if case.edition != "unspecified":
        editions = case.edition.split()
        versions = case.version.split()
        if not any(
            f"xml{version.replace('.', '_')}_{edition}e" in target.features
            for version in versions
            for edition in editions
            if f"xml_version_{version.replace('.', '_')}" in target.features
        ):
            return "out-of-profile", "xml-edition"
    needed, reason = requirements(target, case)
    if reason is not None:
        if reason == "optional-error":
            return "optional", reason
        return "out-of-profile", reason
    if target.processor_class == "validating" and "dtd" not in needed:
        return "out-of-profile", "validating-adapter-requires-dtd"
    missing = needed.difference(target.features)
    if missing:
        return "unsupported-feature", "missing:" + ",".join(sorted(missing))
    if case.case_type == "invalid":
        return ("reject" if target.processor_class == "validating" else "accept"), ""
    if case.case_type == "not-wf":
        return "reject", ""
    return "accept", ""


def observe(target: Target, case: Case, args: argparse.Namespace) -> str:
    command = [
        "prlimit",
        f"--as={args.address_space_mib * 1024 * 1024}",
        f"--cpu={args.cpu_seconds}",
        f"--nofile={args.open_files}",
        "--",
        target.executable,
        case.input_path,
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
        return "timeout"
    except OSError:
        return "error-exec"
    if completed.returncode == 0:
        return "accept"
    if completed.returncode == 2:
        return "reject"
    return f"error-{completed.returncode}"


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


def main() -> int:
    args = parse_args()
    if shutil.which("prlimit") is None:
        print("W3C runner requires prlimit from util-linux", file=sys.stderr)
        return 1
    if (
        args.address_space_mib <= 0
        or args.cpu_seconds <= 0
        or args.open_files <= 0
        or args.timeout <= 0
    ):
        print("resource limits and timeout must be positive", file=sys.stderr)
        return 64
    limit_probe = subprocess.run(
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
    if limit_probe.returncode != 0:
        print("could not apply configured W3C process limits", file=sys.stderr)
        return 1
    suite = args.suite.resolve()
    if not (suite / "xmlconf.xml").is_file():
        print(f"W3C suite not found at {suite}", file=sys.stderr)
        return 1
    try:
        targets = read_targets(args.targets, args.bin_dir, set(args.target))
        cases = read_cases(suite)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    if len(cases) < 2000:
        print(f"catalog discovery found only {len(cases)} cases", file=sys.stderr)
        return 1

    args.results.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
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
    totals: Counter[str] = Counter()
    exclusion_reasons: Counter[tuple[str, str]] = Counter()
    with args.results.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        for target in targets:
            if not target.executable.is_file():
                print(f"missing executable: {target.executable}", file=sys.stderr)
                return 1
            counts: Counter[str] = Counter()
            for case in cases:
                if not case.input_path.is_file():
                    expected = "unknown"
                    reason = "missing-input"
                    encoding = "missing"
                    observed = "missing"
                    verdict = "error"
                else:
                    expected, reason = expectation(target, case)
                    encoding = input_encoding(case.input_path)
                if not case.input_path.is_file():
                    pass
                elif expected in NON_APPLICABLE_VERDICTS:
                    observed = "not-run"
                    verdict = expected
                else:
                    observed = observe(target, case, args)
                    if observed == "timeout" or observed.startswith("error-"):
                        verdict = "error"
                    else:
                        verdict = "pass" if observed == expected else "fail"
                counts[verdict] += 1
                totals[verdict] += 1
                if verdict in NON_APPLICABLE_VERDICTS:
                    if not reason:
                        print(
                            f"{target.name}: {case.test_id}: exclusion has no reason",
                            file=sys.stderr,
                        )
                        return 1
                    exclusion_reasons[(verdict, reason)] += 1
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
            print(
                f"{target.name:<22} applicable={counts['pass'] + counts['fail']:<4} "
                f"pass={counts['pass']:<4} fail={counts['fail']:<4} "
                f"unsupported-feature={counts['unsupported-feature']:<4} "
                f"out-of-profile={counts['out-of-profile']:<4} "
                f"optional={counts['optional']:<3} error={counts['error']:<3}"
            )
    print(
        f"catalog={len(cases)} pass={totals['pass']} fail={totals['fail']} "
        f"unsupported-feature={totals['unsupported-feature']} "
        f"out-of-profile={totals['out-of-profile']} optional={totals['optional']} "
        f"error={totals['error']}"
    )
    for (verdict, reason), count in sorted(exclusion_reasons.items()):
        print(f"excluded {verdict} {reason}: {count}")
    print(f"results: {args.results}")
    return 1 if totals["fail"] or totals["error"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
