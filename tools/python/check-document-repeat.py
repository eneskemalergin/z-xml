#!/usr/bin/env python3
"""Qualify repeated public Document construction over fixed schedules."""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from qualification_io import read_limited

CORPUS_SCHEMA = "z-xml-document-repeat-v1"
TARGET_SCHEMA = "z-xml-targets-v1"
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
MANIFEST_FIELDS = {
    "id",
    "path",
    "actual_bytes",
    "classification",
    "resource_paths",
    "targets",
    "program_args",
    "expected_result",
}
BASE_PHASE_FIELDS = {
    "documents",
    "input_bytes",
    "guard",
    "retained_capacity_bytes",
    "retained_capacity_total_bytes",
}
VERIFY_FIELDS = {"elements", "attributes", "text_bytes", "common_checksum"}
MEMORY_FIELDS = {
    "parse_requested_bytes",
    "parse_temporary_bytes",
    "parse_peak_live_bytes",
    "parse_allocator_operations",
    "parse_live_after_deinit_bytes",
    "reader_requested_bytes",
    "reader_temporary_bytes",
    "reader_peak_live_bytes",
    "reader_allocator_operations",
    "reader_live_after_deinit_bytes",
}
TIMING_FIELDS = {"parse_ns", "parse_deinit_ns", "reader_ns", "reader_deinit_ns"}
RESULT_FIELDS = (
    "target",
    "workload",
    "classification",
    "verdict",
    "work_lane",
    "input_model",
    "program_args",
    "status",
    "primary_documents",
    "next_documents",
    "primary_input_bytes",
    "next_input_bytes",
    "primary_retained_capacity_bytes",
    "next_retained_capacity_bytes",
    "primary_retained_capacity_total_bytes",
    "next_retained_capacity_total_bytes",
    "primary_parse_requested_bytes",
    "next_parse_requested_bytes",
    "primary_parse_temporary_bytes",
    "next_parse_temporary_bytes",
    "primary_reader_requested_bytes",
    "next_reader_requested_bytes",
    "primary_reader_temporary_bytes",
    "next_reader_temporary_bytes",
    "primary_parse_peak_live_bytes",
    "next_parse_peak_live_bytes",
    "primary_reader_peak_live_bytes",
    "next_reader_peak_live_bytes",
    "primary_parse_allocator_operations",
    "next_parse_allocator_operations",
    "primary_reader_allocator_operations",
    "next_reader_allocator_operations",
    "primary_parse_ns",
    "next_parse_ns",
    "primary_parse_deinit_ns",
    "next_parse_deinit_ns",
    "primary_reader_ns",
    "next_reader_ns",
    "primary_reader_deinit_ns",
    "next_reader_deinit_ns",
    "live_after_deinit_bytes",
)
REQUIRED_SCHEDULES = {
    "document-repeat-small": (4096, None, 0),
    "document-repeat-large": (8, None, 0),
    "document-repeat-large-small": (1, "mixed-16k.xml", 4096),
}
MAX_OUTPUT_BYTES = 64 * 1024


@dataclass(frozen=True)
class Target:
    program: Path


@dataclass(frozen=True)
class Workload:
    name: str
    source: Path
    resources: tuple[Path, ...]
    arguments: tuple[str, ...]
    iterations: int
    next_source: Path | None
    next_iterations: int
    expected: dict[str, object]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=300.0)
    return parser.parse_args()


def file_identity(path: Path) -> tuple[int, int]:
    stat = path.stat()
    return stat.st_size, stat.st_mtime_ns


def decode_json(value: str) -> object:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, item in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON field {key}")
            result[key] = item
        return result

    def reject_constant(value: str) -> object:
        raise ValueError(f"invalid JSON number {value}")

    return json.loads(
        value, object_pairs_hook=unique_object, parse_constant=reject_constant
    )


def read_target(path: Path, bin_dir: Path) -> Target:
    lines = read_limited(path).decode("utf-8").splitlines()
    if len(lines) < 3 or lines[0].removeprefix("#").strip() != TARGET_SCHEMA:
        raise ValueError(f"{path}: unsupported target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{path}: invalid target header")
    matches: list[Target] = []
    root = bin_dir.resolve()
    for line_number, line in enumerate(lines[2:], 3):
        if not line or line.startswith("#"):
            raise ValueError(f"{path}:{line_number}: invalid target row")
        fields = line.split("\t")
        if len(fields) != 6:
            raise ValueError(f"{path}:{line_number}: expected six target fields")
        name, executable, processor, features, lane, input_model = fields
        if name != "z-xml-document-repeat":
            continue
        program = (root / executable).resolve()
        if not program.is_relative_to(root):
            raise ValueError(f"{path}:{line_number}: executable escapes bin directory")
        feature_set = frozenset(features.split(","))
        required = {
            "document",
            "document_repeat_protocol",
            "memory_report",
            "timing_report",
        }
        if (
            processor != "partial"
            or lane != "document-repeat"
            or input_model != "streaming-reader"
            or required.difference(feature_set)
        ):
            raise ValueError(f"{path}:{line_number}: invalid repeat target contract")
        matches.append(Target(program))
    if len(matches) != 1:
        raise ValueError(f"{path}: expected one repeated Document target")
    if not matches[0].program.is_file() or not os.access(matches[0].program, os.X_OK):
        raise ValueError(f"{matches[0].program}: missing executable")
    return matches[0]


def valid_expected(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "elements",
        "attributes",
        "text_bytes",
        "checksum",
    }:
        return False
    return (
        all(
            type(value[field]) is int and value[field] >= 0
            for field in ("elements", "attributes", "text_bytes")
        )
        and isinstance(value["checksum"], str)
        and len(value["checksum"]) == 16
        and all(byte in "0123456789abcdef" for byte in value["checksum"])
    )


def read_workloads(path: Path) -> list[Workload]:
    lines = read_limited(path).decode("utf-8").splitlines()
    if not lines or lines[0].removeprefix("#").strip() != CORPUS_SCHEMA:
        raise ValueError(f"{path}: unsupported corpus schema")
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    if rows.fieldnames is None or set(rows.fieldnames) != MANIFEST_FIELDS:
        raise ValueError(f"{path}: unexpected manifest columns")
    root = path.parent.resolve()
    workloads: list[Workload] = []
    names: set[str] = set()
    for line_number, row in enumerate(rows, 3):
        name = row["id"]
        if name in names or name not in REQUIRED_SCHEDULES:
            raise ValueError(f"{path}:{line_number}: unexpected schedule")
        names.add(name)
        source = (root / row["path"]).resolve()
        if not source.is_relative_to(root) or not source.is_file():
            raise ValueError(f"{path}:{line_number}: invalid source")
        if source.stat().st_size != int(row["actual_bytes"]):
            raise ValueError(f"{path}:{line_number}: source size differs")
        if row["classification"] != "benchmark-valid":
            raise ValueError(f"{path}:{line_number}: invalid classification")
        if row["targets"] != "z-xml-document-repeat":
            raise ValueError(f"{path}:{line_number}: invalid target")
        resources: list[Path] = []
        if row["resource_paths"] != "-":
            for value in row["resource_paths"].split(","):
                resource = (root / value).resolve()
                if not resource.is_relative_to(root) or not resource.is_file():
                    raise ValueError(f"{path}:{line_number}: invalid resource")
                resources.append(resource)
        if len(resources) != len(set(resources)):
            raise ValueError(f"{path}:{line_number}: duplicate resource")
        expected_iterations, expected_next, expected_next_iterations = (
            REQUIRED_SCHEDULES[name]
        )
        next_source = None
        expected_arguments = [f"--repeat={expected_iterations}"]
        if expected_next is not None:
            if len(resources) != 1 or resources[0].name != expected_next:
                raise ValueError(f"{path}:{line_number}: transition source differs")
            next_source = resources[0]
            next_name = os.path.relpath(next_source, start=source.parent)
            expected_arguments.extend(
                (
                    f"--next-file={next_name}",
                    f"--next-repeat={expected_next_iterations}",
                )
            )
        elif resources:
            raise ValueError(f"{path}:{line_number}: unused resource")
        arguments = tuple(row["program_args"].split())
        if arguments != tuple(expected_arguments):
            raise ValueError(f"{path}:{line_number}: schedule differs")
        expected = decode_json(row["expected_result"])
        if not isinstance(expected, dict) or set(expected) != {"primary", "next"}:
            raise ValueError(f"{path}:{line_number}: invalid expected result")
        if not valid_expected(expected["primary"]):
            raise ValueError(f"{path}:{line_number}: invalid primary result")
        if (next_source is None) != (expected["next"] is None):
            raise ValueError(f"{path}:{line_number}: transition result differs")
        if expected["next"] is not None and not valid_expected(expected["next"]):
            raise ValueError(f"{path}:{line_number}: invalid transition result")
        workloads.append(
            Workload(
                name,
                source,
                tuple(resources),
                arguments,
                expected_iterations,
                next_source,
                expected_next_iterations,
                expected,
            )
        )
    if names != set(REQUIRED_SCHEDULES):
        raise ValueError(f"{path}: required schedules differ")
    by_name = {workload.name: workload for workload in workloads}
    small = by_name["document-repeat-small"]
    large = by_name["document-repeat-large"]
    transition = by_name["document-repeat-large-small"]
    if transition.source != large.source or transition.next_source != small.source:
        raise ValueError(f"{path}: repeated Document source roles differ")
    return workloads


def run_process(command: list[str], timeout: float) -> tuple[int, str, str]:
    prlimit = shutil.which("prlimit")
    if prlimit is None:
        raise ValueError("prlimit from util-linux is required")
    limited = [prlimit, f"--fsize={MAX_OUTPUT_BYTES}", "--", *command]
    with (
        tempfile.TemporaryFile() as stdout_file,
        tempfile.TemporaryFile() as stderr_file,
    ):
        process = subprocess.Popen(
            limited,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            start_new_session=True,
        )
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise ValueError(f"command timed out: {' '.join(command)}")
        except KeyboardInterrupt:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout = stdout_file.read(MAX_OUTPUT_BYTES + 1)
        stderr = stderr_file.read(MAX_OUTPUT_BYTES + 1)
    if len(stdout) > MAX_OUTPUT_BYTES or len(stderr) > MAX_OUTPUT_BYTES:
        raise ValueError("command output exceeded the protocol limit")
    return process.returncode, stdout.decode("utf-8"), stderr.decode("utf-8")


def phase_fields(mode: str) -> set[str]:
    if mode == "verify":
        return BASE_PHASE_FIELDS | VERIFY_FIELDS
    if mode == "memory":
        return BASE_PHASE_FIELDS | MEMORY_FIELDS
    if mode == "timing":
        return BASE_PHASE_FIELDS | TIMING_FIELDS
    if mode == "summary":
        return BASE_PHASE_FIELDS
    raise ValueError(f"unsupported result mode {mode}")


def check_phase(
    phase: object,
    mode: str,
    documents: int,
    source: Path,
    expected: object,
) -> dict[str, object]:
    if not isinstance(phase, dict) or set(phase) != phase_fields(mode):
        raise ValueError(f"{source}: invalid {mode} phase fields")
    integers = set(phase) - {"guard", "common_checksum"}
    if any(type(phase[field]) is not int or phase[field] < 0 for field in integers):
        raise ValueError(f"{source}: invalid {mode} phase integer")
    if phase["documents"] != documents or phase["input_bytes"] != source.stat().st_size:
        raise ValueError(f"{source}: repeated work differs")
    retained = phase["retained_capacity_bytes"]
    if retained <= 0 or phase["retained_capacity_total_bytes"] != retained * documents:
        raise ValueError(f"{source}: retained ownership differs")
    guard = phase["guard"]
    if (
        not isinstance(guard, str)
        or len(guard) != 16
        or any(byte not in "0123456789abcdef" for byte in guard)
    ):
        raise ValueError(f"{source}: invalid ownership guard")
    if mode == "verify":
        if not isinstance(expected, dict):
            raise ValueError(f"{source}: missing expected result")
        observed = {
            "elements": phase["elements"],
            "attributes": phase["attributes"],
            "text_bytes": phase["text_bytes"],
            "checksum": phase["common_checksum"],
        }
        if observed != expected:
            raise ValueError(f"{source}: repeated semantic result differs")
    elif mode == "memory":
        if phase["parse_requested_bytes"] < phase["retained_capacity_total_bytes"]:
            raise ValueError(f"{source}: parse allocation accounting differs")
        if phase["parse_temporary_bytes"] != (
            phase["parse_requested_bytes"] - phase["retained_capacity_total_bytes"]
        ):
            raise ValueError(f"{source}: parse temporary bytes differ")
        if (
            phase["parse_peak_live_bytes"] < retained
            or phase["parse_allocator_operations"] <= 0
            or phase["reader_requested_bytes"] < phase["reader_temporary_bytes"]
            or phase["reader_peak_live_bytes"] <= 0
            or phase["reader_allocator_operations"] <= 0
            or phase["parse_live_after_deinit_bytes"] != 0
            or phase["reader_live_after_deinit_bytes"] != 0
        ):
            raise ValueError(f"{source}: repeated memory invariant failed")
    elif mode == "timing":
        if phase["parse_ns"] <= 0 or phase["reader_ns"] <= 0:
            raise ValueError(f"{source}: repeated timing is empty")
    return phase


def check_result(
    value: object, mode: str, workload: Workload
) -> tuple[dict[str, object], dict[str, object] | None]:
    if not isinstance(value, dict) or set(value) != {
        "mode",
        "primary",
        "next",
        "total_documents",
        "caller_input_storage_bytes",
        "live_after_deinit_bytes",
    }:
        raise ValueError(f"{workload.name}: invalid result fields")
    if (
        value["mode"] != mode
        or value["total_documents"] != workload.iterations + workload.next_iterations
        or value["caller_input_storage_bytes"] != 64 * 1024
        or value["live_after_deinit_bytes"] != 0
    ):
        raise ValueError(f"{workload.name}: invalid result contract")
    primary = check_phase(
        value["primary"],
        mode,
        workload.iterations,
        workload.source,
        workload.expected["primary"],
    )
    if workload.next_source is None:
        if value["next"] is not None:
            raise ValueError(f"{workload.name}: unexpected transition result")
        return primary, None
    next_phase = check_phase(
        value["next"],
        mode,
        workload.next_iterations,
        workload.next_source,
        workload.expected["next"],
    )
    return primary, next_phase


def run_mode(
    target: Target,
    workload: Workload,
    mode: str,
    timeout: float,
) -> tuple[dict[str, object], dict[str, object] | None]:
    report_argument = {
        "summary": (),
        "verify": ("--verify",),
        "memory": ("--report-memory",),
        "timing": ("--report-timing",),
    }[mode]
    command = [
        str(target.program),
        *workload.arguments,
        *report_argument,
        str(workload.source),
    ]
    status, stdout, stderr = run_process(command, timeout)
    if status != 0 or stderr or stdout.count("\n") != 1:
        raise ValueError(f"{workload.name}/{mode}: status or output differs")
    return check_result(decode_json(stdout), mode, workload)


def result_row(
    workload: Workload,
    memory: tuple[dict[str, object], dict[str, object] | None],
    timing: tuple[dict[str, object], dict[str, object] | None],
) -> dict[str, object]:
    primary_memory, next_memory = memory
    primary_timing, next_timing = timing

    def field(phase: dict[str, object] | None, name: str) -> object:
        return phase[name] if phase is not None else "-"

    return {
        "target": "z-xml-document-repeat",
        "workload": workload.name,
        "classification": "benchmark-valid",
        "verdict": "pass",
        "work_lane": "document-repeat",
        "input_model": "streaming-reader",
        "program_args": " ".join(workload.arguments),
        "status": 0,
        "primary_documents": workload.iterations,
        "next_documents": workload.next_iterations or "-",
        "primary_input_bytes": workload.source.stat().st_size,
        "next_input_bytes": (
            workload.next_source.stat().st_size if workload.next_source else "-"
        ),
        "primary_retained_capacity_bytes": primary_memory["retained_capacity_bytes"],
        "next_retained_capacity_bytes": field(next_memory, "retained_capacity_bytes"),
        "primary_retained_capacity_total_bytes": primary_memory[
            "retained_capacity_total_bytes"
        ],
        "next_retained_capacity_total_bytes": field(
            next_memory, "retained_capacity_total_bytes"
        ),
        "primary_parse_requested_bytes": primary_memory["parse_requested_bytes"],
        "next_parse_requested_bytes": field(next_memory, "parse_requested_bytes"),
        "primary_parse_temporary_bytes": primary_memory["parse_temporary_bytes"],
        "next_parse_temporary_bytes": field(next_memory, "parse_temporary_bytes"),
        "primary_reader_requested_bytes": primary_memory["reader_requested_bytes"],
        "next_reader_requested_bytes": field(next_memory, "reader_requested_bytes"),
        "primary_reader_temporary_bytes": primary_memory["reader_temporary_bytes"],
        "next_reader_temporary_bytes": field(next_memory, "reader_temporary_bytes"),
        "primary_parse_peak_live_bytes": primary_memory["parse_peak_live_bytes"],
        "next_parse_peak_live_bytes": field(next_memory, "parse_peak_live_bytes"),
        "primary_reader_peak_live_bytes": primary_memory["reader_peak_live_bytes"],
        "next_reader_peak_live_bytes": field(next_memory, "reader_peak_live_bytes"),
        "primary_parse_allocator_operations": primary_memory[
            "parse_allocator_operations"
        ],
        "next_parse_allocator_operations": field(
            next_memory, "parse_allocator_operations"
        ),
        "primary_reader_allocator_operations": primary_memory[
            "reader_allocator_operations"
        ],
        "next_reader_allocator_operations": field(
            next_memory, "reader_allocator_operations"
        ),
        "primary_parse_ns": primary_timing["parse_ns"],
        "next_parse_ns": field(next_timing, "parse_ns"),
        "primary_parse_deinit_ns": primary_timing["parse_deinit_ns"],
        "next_parse_deinit_ns": field(next_timing, "parse_deinit_ns"),
        "primary_reader_ns": primary_timing["reader_ns"],
        "next_reader_ns": field(next_timing, "reader_ns"),
        "primary_reader_deinit_ns": primary_timing["reader_deinit_ns"],
        "next_reader_deinit_ns": field(next_timing, "reader_deinit_ns"),
        "live_after_deinit_bytes": 0,
    }


def main() -> int:
    args = parse_args()
    try:
        if args.timeout <= 0:
            raise ValueError("timeout must be positive")
        manifest = args.manifest.resolve()
        targets_path = args.targets.resolve()
        results = args.results.resolve()
        target = read_target(targets_path, args.bin_dir)
        workloads = read_workloads(manifest)
        input_paths = {
            manifest,
            targets_path,
            target.program,
            *(workload.source for workload in workloads),
            *(resource for workload in workloads for resource in workload.resources),
        }
        if (
            args.results.is_symlink()
            or results.is_relative_to(manifest.parent)
            or results in input_paths
        ):
            raise ValueError("result path overlaps an input or uses a symlink")
        identities = {path: file_identity(path) for path in input_paths}
        results.unlink(missing_ok=True)
        rows: list[dict[str, object]] = []
        observed: dict[str, tuple[dict[str, object], dict[str, object] | None]] = {}
        for workload in workloads:
            summary = run_mode(target, workload, "summary", args.timeout)
            verify = run_mode(target, workload, "verify", args.timeout)
            memory = run_mode(target, workload, "memory", args.timeout)
            timing = run_mode(target, workload, "timing", args.timeout)
            for result in (verify, memory, timing):
                if result[0]["guard"] != summary[0]["guard"]:
                    raise ValueError(
                        f"{workload.name}: primary ownership guard differs"
                    )
                if (result[1] is None) != (summary[1] is None):
                    raise ValueError(f"{workload.name}: transition result differs")
                if result[1] is not None and result[1]["guard"] != summary[1]["guard"]:
                    raise ValueError(
                        f"{workload.name}: transition ownership guard differs"
                    )
            observed[workload.name] = summary
            rows.append(result_row(workload, memory, timing))
        small = observed["document-repeat-small"][0]
        large = observed["document-repeat-large"][0]
        transition = observed["document-repeat-large-small"]
        if transition[1] is None:
            raise ValueError("large-to-small transition result is missing")
        for field in ("guard", "retained_capacity_bytes"):
            if (
                transition[0][field] != large[field]
                or transition[1][field] != small[field]
            ):
                raise ValueError(f"large-to-small {field} differs")
        if any(
            file_identity(path) != identity for path, identity in identities.items()
        ):
            raise ValueError("qualification input changed while running")
        output = io.StringIO(newline="")
        writer = csv.DictWriter(
            output, RESULT_FIELDS, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)
        results.parent.mkdir(parents=True, exist_ok=True)
        temporary: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=results.parent, delete=False
            ) as stream:
                stream.write(output.getvalue())
                temporary = Path(stream.name)
            temporary.replace(results)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        print(f"qualified {len(rows)} repeated Document schedules")
        return 0
    except (
        OSError,
        TypeError,
        UnicodeError,
        ValueError,
        subprocess.SubprocessError,
    ) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
