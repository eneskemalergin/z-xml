#!/usr/bin/env python3
"""Measure Zebrac host noise for one fresh correctness-qualified command."""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import os
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

TARGET_SCHEMAS = {
    "z-xml-targets-v1",
    "z-xml-targets-v2",
    "z-xml-persistent-targets-v1",
}
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
CORPUS_SCHEMAS = {
    "z-xml-generated-v3",
    "z-xml-namespace-benchmark-v1",
    "z-xml-dtd-generated-v1",
    "z-xml-validation-generated-v1",
}
RESOURCE_SCHEMAS = {"z-xml-dtd-generated-v1", "z-xml-validation-generated-v1"}
MAX_CONTROL_BYTES = 16 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
ELIGIBILITY_FIELDS = {"target", "workload", "classification", "verdict"}
EVENT_ELIGIBILITY_FIELDS = {"work_lane", "input_model"}
PERSISTENT_ELIGIBILITY_FIELDS = {
    "input",
    "consumer",
    "chunk_bytes",
    "iterations",
    "program_args",
}
METRIC_UNITS = {
    "wall_time": "nanoseconds",
    "peak_rss": "bytes",
    "minor_faults": "count",
    "major_faults": "count",
    "cpu_cycles": "count",
    "instructions": "count",
    "cache_references": "count",
    "cache_misses": "count",
    "branch_misses": "count",
}


def resolve_zebrac(explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit.resolve()
    command = shutil.which("zebrac")
    return Path(command).resolve() if command is not None else None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--eligibility", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--program-arg", action="append", default=[])
    parser.add_argument(
        "--zebrac",
        type=Path,
        help="Zebrac executable (default: resolve zebrac from PATH)",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--duration-ms", type=int, default=5000)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--warmups", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--max-output-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def file_information(path: Path) -> dict[str, object]:
    stat = path.stat()
    return {"path": str(path), "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def read_limited(path: Path, limit: int = MAX_CONTROL_BYTES) -> bytes:
    if not path.is_file():
        raise ValueError(f"{path}: expected a regular file")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{path}: exceeds the {limit}-byte protocol limit")
    return data


def read_json(path: Path, limit: int) -> object:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        decoded: dict[str, object] = {}
        for key, value in pairs:
            if key in decoded:
                raise ValueError(f"duplicate JSON field {key}")
            decoded[key] = value
        return decoded

    def reject_constant(value: str) -> object:
        raise ValueError(f"invalid JSON number {value}")

    return json.loads(
        read_limited(path, limit),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )


def read_target(path: Path, bin_dir: Path, selected: str) -> dict[str, object]:
    manifest = path.resolve()
    lines = read_limited(manifest).decode("utf-8").splitlines(keepends=True)
    if len(lines) < 3 or lines[0].removeprefix("#").strip() not in TARGET_SCHEMAS:
        raise ValueError(f"{manifest}: unsupported target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{manifest}: invalid target header")
    match: dict[str, object] | None = None
    bin_root = bin_dir.resolve()
    seen: set[str] = set()
    for line_number, line in enumerate(lines[2:], 3):
        if not line.strip():
            continue
        if line.startswith("#"):
            raise ValueError(f"{manifest}:{line_number}: unexpected comment")
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 6:
            raise ValueError(f"{manifest}:{line_number}: expected 6 fields")
        name, executable, processor_class, _features, lane, input_model = fields
        if not all((name, executable, processor_class, lane, input_model)):
            raise ValueError(f"{manifest}:{line_number}: empty target field")
        if name in seen:
            raise ValueError(f"{manifest}:{line_number}: duplicate target {name}")
        seen.add(name)
        if name != selected:
            continue
        program = (bin_root / executable).resolve()
        if not program.is_relative_to(bin_root):
            raise ValueError(f"{selected}: executable escapes the binary directory")
        match = {
            "name": name,
            "program": program,
            "processor_class": processor_class,
            "lane": lane,
            "input_model": input_model,
        }
    if match is None:
        raise ValueError(f"{manifest}: unknown target {selected}")
    return match


def read_workload(path: Path, selected: str) -> dict[str, object]:
    manifest = path.resolve()
    root = manifest.parent
    lines = read_limited(manifest).decode("utf-8").splitlines(keepends=True)
    comments = {line[1:].strip() for line in lines if line.startswith("#")}
    schemas = comments & CORPUS_SCHEMAS
    if len(schemas) != 1:
        raise ValueError(f"{manifest}: unsupported or ambiguous corpus schema")
    schema = next(iter(schemas))
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    required = {"id", "path", "actual_bytes", "classification"}
    if rows.fieldnames is None or required.difference(rows.fieldnames):
        raise ValueError(f"{manifest}: incomplete corpus manifest")
    if schema in RESOURCE_SCHEMAS and "resource_paths" not in rows.fieldnames:
        raise ValueError(f"{manifest}: resource manifest lacks resource paths")
    match: dict[str, object] | None = None
    seen: set[str] = set()
    for line_number, row in enumerate(rows, 2):
        name = row.get("id", "")
        if not name or name in seen:
            raise ValueError(f"{manifest}:{line_number}: invalid workload ID")
        seen.add(name)
        if name != selected:
            continue
        source = (root / row["path"]).resolve()
        if not source.is_relative_to(root) or not source.is_file():
            raise ValueError(f"{selected}: invalid workload path")
        actual_bytes = int(row["actual_bytes"])
        target_bytes = int(row.get("target_bytes") or actual_bytes)
        if source.stat().st_size != actual_bytes or target_bytes != actual_bytes:
            raise ValueError(f"{selected}: workload size differs from the manifest")
        classification = row["classification"]
        if classification not in {"benchmark-valid", "not-well-formed"}:
            raise ValueError(f"{selected}: unsupported classification")
        resources: list[Path] = []
        resource_paths = row.get("resource_paths", "-")
        if resource_paths != "-":
            for value in resource_paths.split(","):
                resource = (root / value).resolve()
                if not resource.is_relative_to(root) or not resource.is_file():
                    raise ValueError(f"{selected}: invalid resource path")
                resources.append(resource)
        match = {
            "name": name,
            "source": source,
            "resources": tuple(resources),
            "classification": classification,
            "schema": schema,
        }
    if match is None:
        raise ValueError(f"{manifest}: unknown workload {selected}")
    return match


def read_eligibility(path: Path, target: str, workload: str) -> list[dict[str, str]]:
    matches: list[dict[str, str]] = []
    with io.StringIO(read_limited(path).decode("utf-8"), newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames is None or ELIGIBILITY_FIELDS.difference(
            reader.fieldnames
        ):
            raise ValueError(f"{path}: incomplete eligibility report")
        fields = set(reader.fieldnames)
        event = EVENT_ELIGIBILITY_FIELDS.issubset(fields)
        persistent = PERSISTENT_ELIGIBILITY_FIELDS.issubset(fields)
        if event == persistent:
            raise ValueError(f"{path}: unsupported or ambiguous eligibility schema")
        required = ELIGIBILITY_FIELDS | (
            EVENT_ELIGIBILITY_FIELDS if event else PERSISTENT_ELIGIBILITY_FIELDS
        )
        for line_number, row in enumerate(reader, 2):
            if any(not row.get(field, "") for field in required):
                raise ValueError(f"{path}:{line_number}: incomplete eligibility row")
            if row.get("target") != target or row.get("workload") != workload:
                continue
            if matches and event:
                raise ValueError(
                    f"{path}:{line_number}: duplicate eligibility for {target}/{workload}"
                )
            if row in matches:
                raise ValueError(
                    f"{path}:{line_number}: duplicate eligibility row for "
                    f"{target}/{workload}"
                )
            matches.append(row)
    if not matches or any(row.get("verdict") != "pass" for row in matches):
        raise ValueError(f"{path}: {target}/{workload} is not eligible")
    return matches


def persistent_arguments(arguments: list[str]) -> tuple[dict[str, str], list[str]]:
    options = {
        "--input": "input",
        "--consumer": "consumer",
        "--chunk-bytes": "chunk_bytes",
        "--iterations": "iterations",
    }
    values: dict[str, str] = {}
    extra: list[str] = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        for option, field in options.items():
            if argument == option:
                if index + 1 >= len(arguments):
                    raise ValueError(f"missing value for {option}")
                value = arguments[index + 1]
                index += 2
                break
            if argument.startswith(option + "="):
                value = argument.removeprefix(option + "=")
                index += 1
                break
        else:
            extra.append(argument)
            index += 1
            continue
        if field in values or not value:
            raise ValueError(f"invalid or duplicate {option}")
        values[field] = value
    return values, extra


def extra_input_paths(arguments: list[str], corpus_root: Path) -> list[Path]:
    paths: list[Path] = []
    for argument in arguments:
        if not argument.startswith("--next-file="):
            continue
        value = argument.removeprefix("--next-file=")
        if not value or paths:
            raise ValueError("invalid or duplicate --next-file")
        path = Path(value).resolve()
        if not path.is_relative_to(corpus_root) or not path.is_file():
            raise ValueError("next input is outside the selected corpus or missing")
        paths.append(path)
    return paths


def check_eligibility(
    row: dict[str, str],
    target: dict[str, object],
    workload: dict[str, object],
    arguments: list[str],
) -> None:
    if row["classification"] != workload["classification"]:
        raise ValueError("eligibility classification differs from the workload")
    if EVENT_ELIGIBILITY_FIELDS.issubset(row):
        qualified_arguments = row.get("program_args")
        if qualified_arguments is None:
            if arguments:
                raise ValueError("event eligibility does not qualify program arguments")
        elif qualified_arguments != (" ".join(arguments) or "-"):
            raise ValueError("eligibility program arguments differ from the command")
        if row.get("work_lane") != target["lane"]:
            raise ValueError("eligibility lane differs from the target")
        if row.get("input_model") != target["input_model"]:
            raise ValueError("eligibility input model differs from the target")
        return
    required = {"input", "consumer", "chunk_bytes", "iterations", "program_args"}
    if required.difference(row):
        raise ValueError("unsupported eligibility schema")
    if (
        target["lane"] not in {"event-persistent", "event-persistent-namespace"}
        or target["input_model"] != "resident-or-stream"
    ):
        raise ValueError("persistent eligibility does not match the target")
    protocol, extra = persistent_arguments(arguments)
    if set(protocol) != {"input", "consumer", "chunk_bytes", "iterations"}:
        raise ValueError("persistent eligibility needs complete program arguments")
    if protocol["input"] not in {"resident", "stream"}:
        raise ValueError("unsupported persistent input model")
    try:
        if int(protocol["chunk_bytes"]) <= 0 or int(protocol["iterations"]) <= 0:
            raise ValueError("persistent sizes must be positive")
    except ValueError as error:
        raise ValueError("invalid persistent size") from error
    for field in ("input", "consumer", "chunk_bytes", "iterations"):
        if row[field] != protocol[field]:
            raise ValueError(f"eligibility {field} differs from the command")
    if row["program_args"] != (" ".join(extra) or "-"):
        raise ValueError("eligibility extra arguments differ from the command")


def run_process(
    command: list[str], timeout: float, max_output_bytes: int
) -> tuple[int, str, str, bool, bool]:
    prlimit = shutil.which("prlimit")
    if prlimit is None:
        raise ValueError("prlimit from util-linux is required")
    limited_command = [prlimit, f"--fsize={max_output_bytes}", "--", *command]
    with (
        tempfile.TemporaryFile() as stdout_file,
        tempfile.TemporaryFile() as stderr_file,
    ):
        process = subprocess.Popen(
            limited_command,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            start_new_session=True,
        )
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        except KeyboardInterrupt:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout = stdout_file.read(max_output_bytes + 1)
        stderr = stderr_file.read(max_output_bytes + 1)
    overflow = len(stdout) > max_output_bytes or len(stderr) > max_output_bytes
    return (
        process.returncode,
        stdout[:max_output_bytes].decode("utf-8", errors="replace"),
        stderr[:max_output_bytes].decode("utf-8", errors="replace"),
        timed_out,
        overflow,
    )


def validate_zebrac_results(
    path: Path,
    commands: list[str],
    duration_ms: int,
    samples: int,
    warmups: int,
    expect_failures: bool,
) -> str | None:
    try:
        report = read_json(path, MAX_OUTPUT_BYTES)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return f"invalid Zebrac JSON: {error}"
    if not isinstance(report, dict) or report.get("schema_version") != 1:
        return "unexpected Zebrac JSON schema"
    config = report.get("config")
    results = report.get("results")
    if not isinstance(config, dict) or not isinstance(results, list):
        return "incomplete Zebrac JSON"
    if (
        config.get("duration_ms") != duration_ms
        or config.get("min_samples") != samples
        or config.get("max_samples") != samples
        or config.get("warmup") != warmups
    ):
        return "Zebrac sampling configuration differs from the request"
    if config.get("allow_failures") is not expect_failures:
        return "Zebrac failure policy differs from the workload"
    if len(results) != len(commands):
        return "Zebrac result count differs from the command count"
    expected_failures = samples if expect_failures else 0
    for index, result in enumerate(results):
        if not isinstance(result, dict) or result.get("command") != commands[index]:
            return f"invalid Zebrac command at index {index}"
        if (
            type(result.get("sample_count")) is not int
            or type(result.get("failed_sample_count")) is not int
            or result["sample_count"] != samples
            or result["failed_sample_count"] != expected_failures
        ):
            return f"invalid Zebrac sample outcome at index {index}"
        for name, unit in METRIC_UNITS.items():
            metric = result.get(name)
            if (
                not isinstance(metric, dict)
                or metric.get("unit") != unit
                or metric.get("sample_count") != samples
            ):
                return f"invalid Zebrac {name} metric at index {index}"
            values = [metric.get(field) for field in ("mean", "std_dev", "min", "max")]
            if (
                any(type(value) not in (int, float) for value in values)
                or any(not math.isfinite(float(value)) for value in values)
                or float(values[1]) < 0
                or float(values[2]) < 0
                or float(values[2]) > float(values[0])
                or float(values[0]) > float(values[3])
            ):
                return f"invalid Zebrac {name} values at index {index}"
    return None


def source_information(root: Path) -> dict[str, object]:
    try:
        revision = run_process(["git", "-C", str(root), "rev-parse", "HEAD"], 5, 4096)
        status = run_process(
            [
                "git",
                "-C",
                str(root),
                "status",
                "--porcelain",
                "--untracked-files=no",
            ],
            5,
            MAX_CONTROL_BYTES,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"revision": None, "tracked_dirty": None}
    revision_valid = revision[0] == 0 and not revision[3] and not revision[4]
    status_valid = status[0] == 0 and not status[3] and not status[4]
    return {
        "revision": revision[1].strip() if revision_valid else None,
        "tracked_dirty": bool(status[1]) if status_valid else None,
    }


def host_information() -> dict[str, object]:
    return {
        "system": platform.system(),
        "kernel": platform.release(),
        "machine": platform.machine(),
        "logical_cpu_count": os.cpu_count(),
        "libc": platform.libc_ver(),
    }


def main() -> int:
    args = parse_args()
    if (
        args.duration_ms <= 0
        or args.samples <= 1
        or args.samples > 10_000
        or args.warmups < 0
        or args.timeout <= 0
        or args.max_output_bytes <= 0
        or args.max_output_bytes > MAX_OUTPUT_BYTES
    ):
        print("invalid sampling, timeout, or output limit", file=sys.stderr)
        return 64

    zebrac = resolve_zebrac(args.zebrac)
    output_dir = args.output_dir.resolve()
    manifest = args.manifest.resolve()
    eligibility_path = args.eligibility.resolve()
    targets_path = args.targets.resolve()
    if not args.dry_run:
        early_outputs = {
            output_dir / "index.json",
            output_dir / "index.json.tmp",
        }
        if (
            args.output_dir.is_symlink()
            or output_dir.is_relative_to(manifest.parent)
            or output_dir.is_relative_to(args.bin_dir.resolve())
            or early_outputs & {manifest, eligibility_path, targets_path}
        ):
            print("output path overlaps an input or uses a symlink", file=sys.stderr)
            return 1
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
            for path in early_outputs:
                path.unlink(missing_ok=True)
        except OSError as error:
            print(error, file=sys.stderr)
            return 1
    try:
        target = read_target(targets_path, args.bin_dir, args.target)
        workload = read_workload(manifest, args.workload)
        eligibility = read_eligibility(eligibility_path, args.target, args.workload)
        matched_rows = 0
        for row in eligibility:
            try:
                check_eligibility(row, target, workload, args.program_arg)
            except ValueError:
                continue
            matched_rows += 1
        if matched_rows != 1:
            raise ValueError(
                "eligibility does not contain one exact command qualification"
            )
        program = target["program"]
        input_path = workload["source"]
        assert isinstance(program, Path)
        assert isinstance(input_path, Path)
        if not program.is_file() or not os.access(program, os.X_OK):
            raise ValueError(f"missing executable program: {program}")
        if zebrac is None:
            raise ValueError("zebrac not found on PATH; pass --zebrac PATH")
        if not zebrac.is_file() or not os.access(zebrac, os.X_OK):
            raise ValueError(f"missing executable Zebrac: {zebrac}")
        identities = {
            "manifest": file_information(manifest),
            "eligibility": file_information(eligibility_path),
            "targets": file_information(targets_path),
            "program": file_information(program),
            "input": file_information(input_path),
            "zebrac": file_information(zebrac),
        }
        for index, path in enumerate(
            extra_input_paths(args.program_arg, manifest.parent)
        ):
            identities[f"extra_input_{index}"] = file_information(path)
        for index, path in enumerate(workload["resources"]):
            identities[f"resource_{index}"] = file_information(path)
        eligibility_mtime = int(identities["eligibility"]["mtime_ns"])
        if eligibility_mtime <= max(
            int(value["mtime_ns"])
            for key, value in identities.items()
            if key not in {"eligibility", "zebrac"}
        ):
            raise ValueError(
                "eligibility is not newer than every measured input and artifact"
            )
        if (
            read_target(targets_path, args.bin_dir, args.target) != target
            or read_workload(manifest, args.workload) != workload
            or read_eligibility(eligibility_path, args.target, args.workload)
            != eligibility
        ):
            raise ValueError("measurement inputs changed while qualifying the command")
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    canonical = [str(program), *args.program_arg, str(input_path)]
    if args.dry_run:
        print(shlex.join(canonical))
        print(
            f"target={args.target} workload={args.workload} "
            f"duration_ms={args.duration_ms} samples={args.samples} "
            f"warmups={args.warmups} timeout={args.timeout:g}"
        )
        return 0

    paths = {
        "raw": output_dir / "zebrac.json",
        "stdout": output_dir / "zebrac.stdout.txt",
        "stderr": output_dir / "zebrac.stderr.txt",
        "index": output_dir / "index.json",
        "temporary": output_dir / "index.json.tmp",
    }
    measured_files = {Path(str(value["path"])) for value in identities.values()}
    if args.output_dir.is_symlink() or set(paths.values()) & measured_files:
        print("output path overlaps an input or uses a symlink", file=sys.stderr)
        return 1
    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        for path in paths.values():
            path.unlink(missing_ok=True)
        version = run_process(
            [str(zebrac), "--version"], args.timeout, args.max_output_bytes
        )
        if version[3]:
            raise ValueError("Zebrac version query timed out")
        if version[4]:
            raise ValueError("Zebrac version output exceeded the limit")
        if version[0] != 0 or not version[1].strip():
            raise ValueError("unable to query Zebrac version")
        version_text = version[1].strip()
        expect_failures = workload["classification"] == "not-well-formed"
        with tempfile.TemporaryDirectory(prefix="z-xml-aa-", dir=output_dir) as temp:
            temp_dir = Path(temp)
            left = temp_dir / "aa-left"
            right = temp_dir / "aa-right"
            left.symlink_to(program)
            right.symlink_to(program)
            commands = [
                shlex.join([str(left), *args.program_arg, str(input_path)]),
                shlex.join([str(right), *args.program_arg, str(input_path)]),
            ]
            command = [
                str(zebrac),
                "--quiet",
                "--duration",
                str(args.duration_ms),
                "--min-samples",
                str(args.samples),
                "--max-samples",
                str(args.samples),
                "--warmup",
                str(args.warmups),
                f"--json={paths['raw']}",
            ]
            if expect_failures:
                command.append("--allow-failures")
            command.extend(["--", *commands])
            completed = run_process(command, args.timeout, args.max_output_bytes)
        paths["stdout"].write_text(completed[1], encoding="utf-8")
        paths["stderr"].write_text(completed[2], encoding="utf-8")
        if completed[3]:
            raise ValueError("Zebrac timed out")
        if completed[4]:
            raise ValueError("Zebrac output exceeded the limit")
        if completed[0] != 0:
            raise ValueError(f"Zebrac returned status {completed[0]}")
        if (
            not paths["raw"].is_file()
            or paths["raw"].stat().st_size > args.max_output_bytes
        ):
            raise ValueError("Zebrac JSON is missing or exceeds the limit")
        result_error = validate_zebrac_results(
            paths["raw"],
            commands,
            args.duration_ms,
            args.samples,
            args.warmups,
            expect_failures,
        )
        if result_error is not None:
            raise ValueError(result_error)
        for key, value in identities.items():
            current = file_information(Path(str(value["path"])))
            if current != value:
                raise ValueError(f"{key} changed during measurement")
        metadata = {
            "schema": "z-xml-zebrac-aa-v3",
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "source": source_information(Path(__file__).resolve().parents[2]),
            "target": {
                "name": args.target,
                "processor_class": target["processor_class"],
                "lane": target["lane"],
                "input_model": target["input_model"],
            },
            "workload": {
                "name": args.workload,
                "classification": workload["classification"],
                "schema": workload["schema"],
            },
            "files": identities,
            "arguments": args.program_arg,
            "sampling": {
                "duration_ms": args.duration_ms,
                "samples": args.samples,
                "warmups": args.warmups,
                "timeout_seconds": args.timeout,
            },
            "host": host_information(),
            "zebrac_version": version_text,
            "raw": paths["raw"].name,
            "stdout": paths["stdout"].name,
            "stderr": paths["stderr"].name,
        }
        paths["temporary"].write_text(
            json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
        )
        paths["temporary"].replace(paths["index"])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        paths["index"].unlink(missing_ok=True)
        paths["temporary"].unlink(missing_ok=True)
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
