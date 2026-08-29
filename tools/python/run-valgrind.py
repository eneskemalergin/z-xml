#!/usr/bin/env python3
"""Run bounded Memcheck checks on one executable or correctness-qualified XML cases.

The result keeps parser status, Valgrind status, and descriptor counts separate. It
does not report parser-owned allocation bytes or process RSS.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import cast

GENERATED_SCHEMA = "z-xml-generated-v3"
FIXTURE_SCHEMA = "z-xml-fixtures-v3"
TARGET_SCHEMAS = {"z-xml-targets-v1", "z-xml-targets-v2"}
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
MAX_CONTROL_BYTES = 16 * 1024 * 1024
MAX_WORKLOAD_BYTES = 1024 * 1024 * 1024
MAX_CASES = 256
DEFAULT_MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_LOG_BYTES = 64 * 1024 * 1024
MAX_TIMEOUT_SECONDS = 600.0
VALGRIND_ERROR_STATUS = 99
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
ERROR_SUMMARY = re.compile(r"ERROR SUMMARY: ([0-9,]+) errors")
DESCRIPTOR_SUMMARY = re.compile(
    r"FILE DESCRIPTORS: ([0-9]+) open \(([0-9]+) (inherited|std)\) at exit\."
)
MEMCHECK_OPTIONS = [
    "--tool=memcheck",
    "--leak-check=full",
    "--show-leak-kinds=definite,indirect,possible",
    "--errors-for-leak-kinds=definite,indirect,possible",
    "--track-fds=yes",
    "--error-exitcode=99",
]
RESULT_FIELDS = [
    "mode",
    "target",
    "case",
    "classification",
    "input",
    "input_bytes",
    "executable",
    "executable_bytes",
    "expected_status",
    "observed_status",
    "semantic_result",
    "valgrind_result",
    "valgrind_errors",
    "open_fds_at_exit",
    "baseline_fds",
    "baseline_fds_kind",
    "result",
    "reason",
    "log",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--eligibility", type=Path)
    parser.add_argument("--targets", type=Path)
    parser.add_argument("--bin-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--valgrind", default="valgrind")
    parser.add_argument("--workload", action="append", default=[])
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--standalone", type=Path)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--max-log-bytes", type=int, default=DEFAULT_MAX_LOG_BYTES)
    return parser.parse_args()


def read_limited(path: Path, limit: int = MAX_CONTROL_BYTES) -> bytes:
    if not path.is_file():
        raise ValueError(f"{path}: expected a regular file")
    if path.stat().st_size > limit:
        raise ValueError(f"{path}: exceeds the {limit}-byte protocol limit")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{path}: exceeds the {limit}-byte protocol limit")
    return data


def require_identifier(value: str, owner: str) -> None:
    if IDENTIFIER.fullmatch(value) is None:
        raise ValueError(f"{owner}: invalid identifier {value!r}")


def read_manifest(path: Path) -> tuple[str, dict[str, dict[str, str]]]:
    lines = read_limited(path).decode("utf-8").splitlines()
    if len(lines) < 3:
        raise ValueError(f"{path}: incomplete manifest")
    if lines[0] == f"# {GENERATED_SCHEMA}":
        if lines[1] != f"# size ceiling: {MAX_WORKLOAD_BYTES} bytes":
            raise ValueError(f"{path}: unexpected workload ceiling")
        header = lines[2].split("\t")
        data_lines = lines[3:]
        case_field = "workload"
        required = {"id", "path", "target_bytes", "actual_bytes", "classification"}
        classifications = {"benchmark-valid", "not-well-formed"}
        first_data_line = 4
    elif lines[0] == f"# {FIXTURE_SCHEMA}":
        if not lines[1].startswith("# "):
            raise ValueError(f"{path}: invalid fixture manifest header")
        header = lines[1].removeprefix("# ").split("\t")
        data_lines = lines[2:]
        case_field = "fixture"
        required = {"id", "path", "classification"}
        classifications = {
            "well-formed",
            "namespace-valid",
            "namespace-invalid",
            "dtd-valid",
            "dtd-invalid",
            "not-well-formed",
        }
        first_data_line = 3
    else:
        raise ValueError(f"{path}: unsupported manifest schema")
    if len(header) != len(set(header)):
        raise ValueError(f"{path}: duplicate manifest column")
    if required.difference(header):
        raise ValueError(f"{path}: incomplete manifest header")

    root = path.parent.resolve()
    rows = csv.DictReader(data_lines, fieldnames=header, delimiter="\t")
    result: dict[str, dict[str, str]] = {}
    seen_paths: set[Path] = set()
    for line_number, row in enumerate(rows, first_data_line):
        if None in row or any(value is None or value == "" for value in row.values()):
            raise ValueError(f"{path}:{line_number}: invalid manifest row")
        case_id = row["id"]
        require_identifier(case_id, f"{path}:{line_number}")
        if case_id in result:
            raise ValueError(f"{path}:{line_number}: duplicate case {case_id}")
        if row["classification"] not in classifications:
            raise ValueError(f"{path}:{line_number}: unsupported classification")
        resolved = (root / row["path"]).resolve()
        try:
            resolved.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{case_id}: path escapes corpus") from error
        if case_field == "workload" and resolved in seen_paths:
            raise ValueError(f"{path}:{line_number}: duplicate workload path")
        seen_paths.add(resolved)
        row["resolved_path"] = str(resolved)
        result[case_id] = row
    if not result:
        raise ValueError(f"{path}: manifest has no cases")
    return case_field, result


def read_targets(path: Path, bin_dir: Path) -> dict[str, dict[str, str | Path]]:
    lines = read_limited(path, 1024 * 1024).decode("utf-8").splitlines()
    if len(lines) < 3:
        raise ValueError(f"{path}: incomplete target manifest")
    if lines[0] not in {f"# {schema}" for schema in TARGET_SCHEMAS}:
        raise ValueError(f"{path}: unsupported target schema")
    if lines[1] != f"# {TARGET_HEADER}":
        raise ValueError(f"{path}: invalid target header")

    root = bin_dir.resolve()
    result: dict[str, dict[str, str | Path]] = {}
    for line_number, line in enumerate(lines[2:], 3):
        if not line:
            continue
        fields = line.split("\t")
        if (
            line.startswith("#")
            or len(fields) != 6
            or any(not field for field in fields)
        ):
            raise ValueError(f"{path}:{line_number}: invalid target row")
        name, executable, _processor_class, _features, work_lane, input_model = fields
        require_identifier(name, f"{path}:{line_number}")
        if name in result:
            raise ValueError(f"{path}:{line_number}: duplicate target {name}")
        program = (root / executable).resolve()
        try:
            program.relative_to(root)
        except ValueError as error:
            raise ValueError(
                f"{name}: executable escapes the binary directory"
            ) from error
        result[name] = {
            "path": program,
            "work_lane": work_lane,
            "input_model": input_model,
        }
    return result


def read_eligibility(
    path: Path,
) -> tuple[str, dict[tuple[str, str], dict[str, str]]]:
    reader = csv.DictReader(
        read_limited(path).decode("utf-8").splitlines(), delimiter="\t"
    )
    if reader.fieldnames is None:
        raise ValueError(f"{path}: missing eligibility header")
    item_fields = {"workload", "fixture"}.intersection(reader.fieldnames)
    if len(item_fields) != 1:
        raise ValueError(f"{path}: invalid eligibility case column")
    item_field = item_fields.pop()
    expected_header = [
        "target",
        "work_lane",
        "input_model",
        item_field,
        "classification",
        "expected",
        "observed",
        "verdict",
        "reason",
    ]
    if reader.fieldnames != expected_header:
        raise ValueError(f"{path}: invalid eligibility header")

    result: dict[tuple[str, str], dict[str, str]] = {}
    for line_number, row in enumerate(reader, 2):
        if None in row or any(value is None or value == "" for value in row.values()):
            raise ValueError(f"{path}:{line_number}: invalid eligibility row")
        pair = (row["target"], row[item_field])
        if pair in result:
            raise ValueError(f"{path}:{line_number}: duplicate eligibility row")
        result[pair] = row
    return item_field, result


def prepare_output(path: Path, protected_paths: list[Path]) -> Path:
    if path.is_symlink():
        raise ValueError(f"output directory is a symlink: {path}")
    output = path.resolve()
    if output.exists() and not output.is_dir():
        raise ValueError(f"output path is not a directory: {output}")
    for protected_path in protected_paths:
        protected = protected_path.resolve()
        if (
            output == protected
            or output.is_relative_to(protected)
            or protected.is_relative_to(output)
        ):
            raise ValueError(f"output directory overlaps an input path: {protected}")
    output.mkdir(parents=True, exist_ok=True)
    owned_paths = [output / "metadata.json", output / "results.tsv"]
    for owned in owned_paths:
        if owned.exists() and owned.is_dir():
            raise ValueError(f"owned output path is a directory: {owned}")
    for owned in owned_paths:
        owned.unlink(missing_ok=True)
    return output


def resolve_valgrind(value: str) -> Path:
    resolved = shutil.which(value)
    if resolved is None:
        raise ValueError(f"Valgrind executable not found: {value}")
    path = Path(resolved).resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError(f"invalid Valgrind executable: {path}")
    return path


def resolve_prlimit() -> Path:
    resolved = shutil.which("prlimit")
    if resolved is None:
        raise ValueError("run-valgrind requires prlimit from util-linux")
    return Path(resolved).resolve()


def executable_metadata(path: Path) -> dict[str, str | int]:
    return {
        "executable": str(path),
        "executable_bytes": path.stat().st_size,
    }


def wait_bounded(process: subprocess.Popen[bytes], timeout: float) -> int | str:
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        pass
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    return "timeout"


def failed_run(
    observed: int | str, valgrind_result: str, reason: str
) -> dict[str, object]:
    return {
        "observed_status": observed,
        "semantic_result": "not-observed",
        "valgrind_result": valgrind_result,
        "valgrind_errors": None,
        "open_fds_at_exit": None,
        "baseline_fds": None,
        "baseline_fds_kind": None,
        "result": "error",
        "reason": reason,
    }


def run_memcheck(
    prlimit: Path,
    valgrind: Path,
    executable: Path,
    arguments: list[str],
    log: Path,
    expected_status: int,
    timeout: float,
    max_log_bytes: int,
) -> dict[str, object]:
    log.unlink(missing_ok=True)
    command = [
        str(prlimit),
        f"--fsize={max_log_bytes}",
        "--",
        str(valgrind),
        *MEMCHECK_OPTIONS,
        f"--log-file={log}",
        str(executable),
        *arguments,
    ]
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except (OSError, subprocess.SubprocessError):
        return failed_run("start-error", "error", "process-start")

    observed = wait_bounded(process, timeout)
    if observed == "timeout":
        return failed_run(observed, "timeout", "timeout")
    if not log.is_file():
        return failed_run(observed, "error", "missing-log")
    try:
        log_data = read_limited(log, max_log_bytes)
    except (OSError, ValueError):
        return failed_run(observed, "output-limit", "log-limit")

    text = log_data.decode("utf-8", errors="replace")
    errors = ERROR_SUMMARY.findall(text)
    descriptors = DESCRIPTOR_SUMMARY.findall(text)
    if len(errors) != 1 or len(descriptors) != 1:
        limited = observed == -signal.SIGXFSZ or len(log_data) >= max_log_bytes
        return failed_run(
            observed,
            "output-limit" if limited else "error",
            "log-limit" if limited else "incomplete-log",
        )

    valgrind_errors = int(errors[0].replace(",", ""))
    open_text, baseline_text, baseline_kind = descriptors[0]
    open_fds = int(open_text)
    baseline_fds = int(baseline_text)
    descriptors_clean = open_fds == baseline_fds
    valgrind_result = "pass" if valgrind_errors == 0 and descriptors_clean else "fail"
    semantic_result = (
        "not-observed"
        if observed == VALGRIND_ERROR_STATUS and valgrind_errors > 0
        else "pass"
        if observed == expected_status
        else "fail"
    )
    reasons: list[str] = []
    if semantic_result == "fail":
        reasons.append("semantic-status")
    elif semantic_result == "not-observed":
        reasons.append("semantic-status-not-observed")
    if valgrind_errors:
        reasons.append("valgrind-errors")
    if not descriptors_clean:
        reasons.append("descriptor-leak")
    passed = semantic_result == "pass" and valgrind_result == "pass"
    return {
        "observed_status": observed,
        "semantic_result": semantic_result,
        "valgrind_result": valgrind_result,
        "valgrind_errors": valgrind_errors,
        "open_fds_at_exit": open_fds,
        "baseline_fds": baseline_fds,
        "baseline_fds_kind": baseline_kind,
        "result": "pass" if passed else "fail",
        "reason": "-" if passed else ",".join(reasons),
    }


def publish(
    output: Path,
    metadata: dict[str, object],
    records: list[dict[str, object]],
    write_tsv: bool,
) -> None:
    metadata_path = output / "metadata.json"
    results_path = output / "results.tsv"
    temporary: list[Path] = []
    results_temporary: Path | None = None
    try:
        if write_tsv:
            with tempfile.NamedTemporaryFile(
                "w", encoding="utf-8", newline="", dir=output, delete=False
            ) as stream:
                results_temporary = Path(stream.name)
                temporary.append(results_temporary)
                writer = csv.DictWriter(
                    stream,
                    fieldnames=RESULT_FIELDS,
                    delimiter="\t",
                    lineterminator="\n",
                )
                writer.writeheader()
                writer.writerows(records)
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=output, delete=False
        ) as stream:
            metadata_temporary = Path(stream.name)
            temporary.append(metadata_temporary)
            json.dump(metadata, stream, indent=2)
            stream.write("\n")
        if results_temporary is not None:
            results_temporary.replace(results_path)
            temporary.remove(results_temporary)
        metadata_temporary.replace(metadata_path)
        temporary.remove(metadata_temporary)
    except BaseException:
        for path in (results_path, metadata_path):
            try:
                path.unlink(missing_ok=True)
            except IsADirectoryError:
                pass
        raise
    finally:
        for path in temporary:
            path.unlink(missing_ok=True)


def metadata(
    mode: str,
    valgrind: Path,
    timeout: float,
    max_log_bytes: int,
    records: list[dict[str, object]],
) -> dict[str, object]:
    return {
        "schema": "z-xml-valgrind-v4",
        "mode": mode,
        "valgrind": str(valgrind),
        "timeout_seconds": timeout,
        "max_log_bytes": max_log_bytes,
        "memcheck_options": MEMCHECK_OPTIONS,
        "cases": records,
    }


def standalone(args: argparse.Namespace) -> int:
    executable = args.standalone.resolve()
    output = prepare_output(args.output_dir, [executable.parent])
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f"invalid standalone executable: {executable}")
    valgrind = resolve_valgrind(args.valgrind)
    prlimit = resolve_prlimit()
    log = output / "standalone.log"
    result = run_memcheck(
        prlimit, valgrind, executable, [], log, 0, args.timeout, args.max_log_bytes
    )
    record = {
        "mode": "standalone",
        "target": "standalone",
        "case": "standalone",
        "classification": None,
        "input": None,
        "input_bytes": None,
        **executable_metadata(executable),
        "expected_status": 0,
        **result,
        "log": log.name,
    }
    report = metadata(
        "standalone", valgrind, args.timeout, args.max_log_bytes, [record]
    )
    publish(output, report, [record], False)
    print(
        f"standalone: {result['result']}; semantic={result['semantic_result']}; "
        f"valgrind={result['valgrind_result']}; status={result['observed_status']}"
    )
    return 0 if result["result"] == "pass" else 1


def corpus_cases(
    args: argparse.Namespace,
    manifest_field: str,
    workloads: dict[str, dict[str, str]],
    targets: dict[str, dict[str, str | Path]],
    eligibility_field: str,
    eligibility: dict[tuple[str, str], dict[str, str]],
) -> list[dict[str, object]]:
    if manifest_field != eligibility_field:
        raise ValueError("manifest and eligibility case columns differ")
    if len(args.workload) != len(set(args.workload)) or len(args.target) != len(
        set(args.target)
    ):
        raise ValueError("duplicate target or case selection")
    unknown = set(args.workload).difference(workloads) | set(args.target).difference(
        targets
    )
    if unknown:
        raise ValueError("unknown selections: " + ",".join(sorted(unknown)))
    if len(args.workload) * len(args.target) > MAX_CASES:
        raise ValueError(f"selection exceeds the {MAX_CASES}-case limit")

    cases: list[dict[str, object]] = []
    ineligible: list[str] = []
    for target_name in args.target:
        target = targets[target_name]
        executable = cast(Path, target["path"])
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"invalid executable for {target_name}: {executable}")
        for case_id in args.workload:
            workload = workloads[case_id]
            row = eligibility.get((target_name, case_id))
            if row is None or row["verdict"] != "pass":
                verdict = "missing" if row is None else row["verdict"]
                ineligible.append(f"{target_name}/{case_id}:{verdict}")
                continue
            if (
                row["work_lane"] != target["work_lane"]
                or row["input_model"] != target["input_model"]
                or row["classification"] != workload["classification"]
                or row["expected"] not in {"accept", "reject"}
                or row["observed"] != row["expected"]
                or row["reason"] != "-"
            ):
                raise ValueError(f"{target_name}/{case_id}: inconsistent passing row")
            input_path = Path(workload["resolved_path"])
            try:
                input_bytes = input_path.stat().st_size
                actual_bytes = int(workload.get("actual_bytes", input_bytes))
                target_bytes = int(workload.get("target_bytes", 0))
            except (OSError, ValueError) as error:
                raise ValueError(f"{case_id}: {error}") from error
            if (
                not input_path.is_file()
                or input_bytes <= 0
                or input_bytes > MAX_WORKLOAD_BYTES
                or input_bytes != actual_bytes
                or (target_bytes and input_bytes != target_bytes)
            ):
                raise ValueError(f"{case_id}: selected input size is invalid")
            cases.append(
                {
                    "target": target_name,
                    "case": case_id,
                    "classification": workload["classification"],
                    "input": input_path,
                    "input_bytes": input_bytes,
                    "executable": executable,
                    "expected_status": 0 if row["expected"] == "accept" else 2,
                }
            )
    if ineligible:
        raise ValueError(
            "selected pairs are not correctness-qualified: " + ",".join(ineligible)
        )
    return cases


def corpus(args: argparse.Namespace) -> int:
    manifest_path = args.manifest.resolve()
    eligibility_path = args.eligibility.resolve()
    targets_path = args.targets.resolve()
    bin_dir = args.bin_dir.resolve()
    output = prepare_output(
        args.output_dir,
        [manifest_path.parent, eligibility_path, targets_path, bin_dir],
    )
    manifest_field, workloads = read_manifest(manifest_path)
    targets = read_targets(targets_path, bin_dir)
    eligibility_field, eligibility = read_eligibility(eligibility_path)
    cases = corpus_cases(
        args,
        manifest_field,
        workloads,
        targets,
        eligibility_field,
        eligibility,
    )
    valgrind = resolve_valgrind(args.valgrind)
    prlimit = resolve_prlimit()
    executables: dict[Path, dict[str, str | int]] = {}
    records: list[dict[str, object]] = []
    for index, case in enumerate(cases, 1):
        executable = cast(Path, case.pop("executable"))
        input_path = cast(Path, case["input"])
        executable_info = executables.get(executable)
        if executable_info is None:
            executable_info = executable_metadata(executable)
            executables[executable] = executable_info
        log = output / f"{index:04d}.log"
        result = run_memcheck(
            prlimit,
            valgrind,
            executable,
            [str(input_path)],
            log,
            int(case["expected_status"]),
            args.timeout,
            args.max_log_bytes,
        )
        record = {
            "mode": "corpus",
            **case,
            "input": str(input_path),
            **executable_info,
            **result,
            "log": log.name,
        }
        records.append(record)
        print(
            f"{record['target']}/{record['case']}: {result['result']}; "
            f"semantic={result['semantic_result']}; "
            f"valgrind={result['valgrind_result']}; status={result['observed_status']}"
        )

    report = metadata("corpus", valgrind, args.timeout, args.max_log_bytes, records)
    report.update(
        {
            "manifest": str(manifest_path),
            "eligibility": str(eligibility_path),
            "targets": str(targets_path),
            "bin_dir": str(bin_dir),
        }
    )
    publish(output, report, records, True)
    return 0 if all(record["result"] == "pass" for record in records) else 1


def main() -> int:
    args = parse_args()
    if (
        not math.isfinite(args.timeout)
        or args.timeout <= 0
        or args.timeout > MAX_TIMEOUT_SECONDS
        or args.max_log_bytes <= 0
        or args.max_log_bytes > MAX_LOG_BYTES
    ):
        print(
            "timeout or max-log-bytes is outside the supported limit", file=sys.stderr
        )
        return 64
    corpus_values = (
        args.manifest,
        args.eligibility,
        args.targets,
        args.bin_dir,
        args.workload,
        args.target,
    )
    corpus_requested = any(bool(value) for value in corpus_values)
    corpus_complete = all(bool(value) for value in corpus_values)
    if args.standalone is not None and corpus_requested:
        print("standalone and corpus modes are mutually exclusive", file=sys.stderr)
        return 64
    if args.standalone is None and not corpus_complete:
        print(
            "corpus mode requires manifest, eligibility, targets, bin-dir, "
            "workload, and target",
            file=sys.stderr,
        )
        return 64
    try:
        return standalone(args) if args.standalone is not None else corpus(args)
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except (csv.Error, OSError, UnicodeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
