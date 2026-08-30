#!/usr/bin/env python3
"""Run correctness-qualified zebrac comparisons in separate work lanes."""

from __future__ import annotations

import argparse
import csv
import fnmatch
import io
import json
import os
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

GENERATED_SCHEMAS = {"z-xml-generated-v3"}
NAMESPACE_SCHEMA = "z-xml-namespace-benchmark-v1"
DTD_SCHEMA = "z-xml-dtd-generated-v1"
VALIDATION_SCHEMA = "z-xml-validation-generated-v1"
VALIDATION_REUSE_SCHEMA = "z-xml-validation-reuse-v1"
RESOURCE_SCHEMAS = {DTD_SCHEMA, VALIDATION_SCHEMA, VALIDATION_REUSE_SCHEMA}
TARGET_SCHEMAS = {
    "z-xml-targets-v1",
    "z-xml-targets-v2",
    "z-xml-persistent-targets-v1",
}
TARGET_HEADER = "name\texecutable\tprocessor_class\tfeatures\twork_lane\tinput_model"
MAX_WORKLOAD_BYTES = 1024 * 1024 * 1024
MAX_CONTROL_BYTES = 16 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
ELIGIBILITY_FIELDS = {"target", "workload", "verdict"}
EVENT_ELIGIBILITY_FIELDS = {"classification", "work_lane", "input_model"}
PERSISTENT_ELIGIBILITY_FIELDS = {
    "classification",
    "input",
    "consumer",
    "chunk_bytes",
    "iterations",
    "program_args",
}


@dataclass(frozen=True)
class Target:
    name: str
    executable: Path
    processor_class: str
    work_lane: str
    input_model: str
    manifest: Path
    manifest_mtime_ns: int


@dataclass(frozen=True)
class Eligibility:
    row: dict[str, str]
    path: Path
    mtime_ns: int
    kind: str


def resolve_zebrac(explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit.resolve()
    command = shutil.which("zebrac")
    return Path(command).resolve() if command is not None else None


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


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--eligibility", type=Path, action="append", required=True)
    parser.add_argument("--targets", type=Path, action="append", default=[])
    parser.add_argument("--bin-dir", type=Path, action="append", required=True)
    parser.add_argument(
        "--zebrac",
        type=Path,
        help="Zebrac executable (default: resolve zebrac from PATH)",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--workload", action="append", required=True, help="Workload ID or glob"
    )
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--lane", action="append", default=[])
    parser.add_argument("--program-arg", action="append", default=[])
    parser.add_argument("--work-multiplier", type=int, default=1)
    parser.add_argument("--case", default="end-to-end")
    parser.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--duration-ms", type=int, default=5000)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--max-output-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--dry-run", action="store_true")
    parser.set_defaults(default_targets=root / "ref" / "targets.tsv")
    return parser.parse_args()


def read_targets(path: Path, bin_dir: Path) -> dict[str, Target]:
    path = path.resolve()
    bin_dir = bin_dir.resolve()
    manifest_mtime_ns = path.stat().st_mtime_ns
    lines = read_limited(path).decode("utf-8").splitlines(keepends=True)
    if len(lines) < 3 or lines[0].removeprefix("#").strip() not in TARGET_SCHEMAS:
        raise ValueError(f"{path}: unsupported target schema")
    if lines[1].removeprefix("#").strip() != TARGET_HEADER:
        raise ValueError(f"{path}: invalid target header")
    targets: dict[str, Target] = {}
    for line_number, line in enumerate(lines[2:], 3):
        if not line.strip():
            continue
        if line.startswith("#"):
            raise ValueError(f"{path}:{line_number}: unexpected comment")
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 6:
            raise ValueError(f"{path}:{line_number}: expected 6 fields")
        name, executable, processor_class, _features, work_lane, input_model = fields
        if not all((name, executable, processor_class, work_lane, input_model)):
            raise ValueError(f"{path}:{line_number}: empty target field")
        if name in targets:
            raise ValueError(f"{path}:{line_number}: duplicate target {name}")
        executable_path = (bin_dir / executable).resolve()
        if not executable_path.is_relative_to(bin_dir):
            raise ValueError(f"{name}: executable escapes the binary directory")
        targets[name] = Target(
            name=name,
            executable=executable_path,
            processor_class=processor_class,
            work_lane=work_lane,
            input_model=input_model,
            manifest=path,
            manifest_mtime_ns=manifest_mtime_ns,
        )
    if not targets:
        raise ValueError(f"{path}: empty target manifest")
    if path.stat().st_mtime_ns != manifest_mtime_ns:
        raise ValueError(f"{path}: target manifest changed while reading")
    return targets


def read_workloads(path: Path) -> tuple[dict[str, dict[str, str]], str]:
    root = path.parent.resolve()
    lines = read_limited(path).decode("utf-8").splitlines(keepends=True)
    comments = {line[1:].strip() for line in lines if line.startswith("#")}
    generated_schema = GENERATED_SCHEMAS.intersection(comments)
    named_schemas = {
        schema
        for schema in (
            NAMESPACE_SCHEMA,
            DTD_SCHEMA,
            VALIDATION_SCHEMA,
            VALIDATION_REUSE_SCHEMA,
        )
        if schema in comments
    }
    if len(generated_schema) + len(named_schemas) != 1:
        raise ValueError(f"{path}: unsupported or ambiguous corpus schema")
    if generated_schema and f"size ceiling: {MAX_WORKLOAD_BYTES} bytes" not in comments:
        raise ValueError(f"{path}: unexpected workload ceiling")
    schema = next(iter(named_schemas)) if named_schemas else max(generated_schema)
    workloads: dict[str, dict[str, str]] = {}
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    required = {"id", "path", "actual_bytes", "classification"}
    if generated_schema:
        required.add("target_bytes")
    if schema in RESOURCE_SCHEMAS:
        required.add("resource_paths")
    if rows.fieldnames is None or required.difference(rows.fieldnames):
        raise ValueError(f"{path}: incomplete generated manifest")
    for row in rows:
        if not row["id"]:
            raise ValueError(f"{path}: empty workload ID")
        if row["id"] in workloads:
            raise ValueError(f"{path}: duplicate workload ID {row['id']}")
        workloads[row["id"]] = row
    if not workloads:
        raise ValueError(f"{path}: empty manifest")
    seen_paths: set[Path] = set()
    for workload in workloads.values():
        resolved = (root / workload["path"]).resolve()
        try:
            resolved.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{workload['id']}: path escapes corpus") from error
        if not resolved.is_file():
            raise ValueError(f"{workload['id']}: missing {resolved}")
        if resolved in seen_paths and schema not in {
            DTD_SCHEMA,
            VALIDATION_REUSE_SCHEMA,
        }:
            raise ValueError(f"{workload['id']}: duplicate workload path")
        seen_paths.add(resolved)
        actual = resolved.stat().st_size
        manifest_size = int(workload["actual_bytes"])
        target_size = int(workload.get("target_bytes", manifest_size))
        if actual != manifest_size:
            raise ValueError(f"{workload['id']}: size differs from manifest")
        if target_size and actual != target_size:
            raise ValueError(f"{workload['id']}: size differs from target")
        if actual > MAX_WORKLOAD_BYTES:
            raise ValueError(f"{workload['id']}: exceeds the 1 GiB ceiling")
        if workload["classification"] not in {"benchmark-valid", "not-well-formed"}:
            raise ValueError(f"{workload['id']}: unsupported classification")
        workload["resolved_path"] = str(resolved)
        workload["source_mtime_ns"] = str(resolved.stat().st_mtime_ns)
        resources: list[Path] = []
        if schema in RESOURCE_SCHEMAS and workload["resource_paths"] != "-":
            for value in workload["resource_paths"].split(","):
                resource = (root / value).resolve()
                if not resource.is_relative_to(root) or not resource.is_file():
                    raise ValueError(f"{workload['id']}: invalid resource path")
                resources.append(resource)
        workload["resolved_resources"] = resources
        workload["resource_mtime_ns"] = str(
            max((resource.stat().st_mtime_ns for resource in resources), default=0)
        )
    return workloads, schema


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


def read_eligibility(path: Path) -> dict[tuple[str, str], list[Eligibility]]:
    path = path.resolve()
    mtime_ns = path.stat().st_mtime_ns
    eligibility: dict[tuple[str, str], list[Eligibility]] = {}
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
        if event:
            kind = "event"
            required = ELIGIBILITY_FIELDS | EVENT_ELIGIBILITY_FIELDS
        else:
            kind = "persistent"
            required = ELIGIBILITY_FIELDS | PERSISTENT_ELIGIBILITY_FIELDS
        for line_number, row in enumerate(reader, 2):
            if any(not row.get(field, "") for field in required):
                raise ValueError(f"{path}:{line_number}: incomplete eligibility row")
            target = row["target"]
            workload = row["workload"]
            pair = (target, workload)
            current = eligibility.setdefault(pair, [])
            if kind == "event" and current:
                raise ValueError(
                    f"{path}:{line_number}: duplicate eligibility for "
                    f"{target}/{workload}"
                )
            identity = tuple(row[field] for field in sorted(required))
            if any(
                tuple(item.row[field] for field in sorted(required)) == identity
                for item in current
            ):
                raise ValueError(
                    f"{path}:{line_number}: duplicate eligibility row for "
                    f"{target}/{workload}"
                )
            current.append(
                Eligibility(
                    row=row,
                    path=path,
                    mtime_ns=mtime_ns,
                    kind=kind,
                )
            )
    if not eligibility:
        raise ValueError(f"{path}: empty eligibility report")
    if path.stat().st_mtime_ns != mtime_ns:
        raise ValueError(f"{path}: eligibility report changed while reading")
    return eligibility


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


def eligibility_match(
    eligibility: list[Eligibility] | None,
    target: Target,
    workload: dict[str, str],
    program_arguments: list[str],
    work_multiplier: int,
    manifest_mtime_ns: int,
) -> tuple[bool, str, str]:
    if eligibility is None:
        return False, "missing-eligibility", target.input_model
    matches: list[tuple[bool, str, str]] = []
    for item in eligibility:
        row = item.row
        if row["verdict"] != "pass":
            matches.append((False, row["verdict"], target.input_model))
            continue
        if row["classification"] != workload["classification"]:
            matches.append((False, "classification-mismatch", target.input_model))
            continue
        newest_input = max(
            manifest_mtime_ns,
            target.manifest_mtime_ns,
            target.executable.stat().st_mtime_ns,
            int(workload["source_mtime_ns"]),
            int(workload["resource_mtime_ns"]),
        )
        if item.mtime_ns <= newest_input:
            matches.append((False, "stale-eligibility", target.input_model))
            continue
        if item.kind == "event":
            qualified_arguments = row.get("program_args")
            if (work_multiplier != 1 and target.work_lane != "validation-reuse") or (
                qualified_arguments is None and program_arguments
            ):
                matches.append(
                    (False, "unqualified-program-arguments", target.input_model)
                )
            elif qualified_arguments is not None and qualified_arguments != (
                " ".join(program_arguments) or "-"
            ):
                matches.append(
                    (False, "program-arguments-mismatch", target.input_model)
                )
            elif row["work_lane"] != target.work_lane:
                matches.append((False, "lane-mismatch", target.input_model))
            elif row["input_model"] != target.input_model:
                matches.append((False, "input-model-mismatch", target.input_model))
            else:
                matches.append((True, "pass", target.input_model))
            continue

        try:
            protocol, extra = persistent_arguments(program_arguments)
        except ValueError:
            matches.append((False, "invalid-program-arguments", target.input_model))
            continue
        if set(protocol) != {"input", "consumer", "chunk_bytes", "iterations"}:
            matches.append(
                (False, "incomplete-persistent-arguments", target.input_model)
            )
            continue
        if protocol["input"] not in {"resident", "stream"}:
            matches.append((False, "unsupported-persistent-input", protocol["input"]))
            continue
        differing = next(
            (
                field
                for field in ("input", "consumer", "chunk_bytes", "iterations")
                if row[field] != protocol[field]
            ),
            None,
        )
        if differing is not None:
            matches.append(
                (
                    False,
                    f"{differing.replace('_', '-')}-mismatch",
                    protocol["input"],
                )
            )
            continue
        if row["program_args"] != (" ".join(extra) or "-"):
            matches.append(
                (False, "extra-program-arguments-mismatch", protocol["input"])
            )
            continue
        try:
            iterations = int(protocol["iterations"])
            chunk_bytes = int(protocol["chunk_bytes"])
        except ValueError:
            matches.append((False, "invalid-persistent-arguments", protocol["input"]))
            continue
        if (
            target.work_lane not in {"event-persistent", "event-persistent-namespace"}
            or target.input_model != "resident-or-stream"
            or iterations <= 0
            or chunk_bytes <= 0
            or iterations != work_multiplier
        ):
            matches.append((False, "persistent-work-mismatch", protocol["input"]))
        else:
            matches.append((True, "pass", protocol["input"]))
    passing = [match for match in matches if match[0]]
    if len(passing) > 1:
        return False, "ambiguous-eligibility", passing[0][2]
    if passing:
        return passing[0]
    if eligibility[0].kind == "persistent":
        return False, "no-matching-persistent-qualification", target.input_model
    return matches[0]


def validation_reuse_multiplier(
    arguments: list[str], workload: dict[str, object]
) -> int:
    values: dict[str, str] = {}
    for argument in arguments:
        if not argument.startswith("--") or "=" not in argument:
            raise ValueError("invalid validation reuse program argument")
        name, value = argument[2:].split("=", 1)
        if name not in {"dtd", "iterations", "next-file", "next-iterations"}:
            raise ValueError("unsupported validation reuse program argument")
        if not value or name in values:
            raise ValueError("invalid validation reuse program argument")
        values[name] = value
    if set(values) not in (
        {"dtd", "iterations"},
        {"dtd", "iterations", "next-file", "next-iterations"},
    ):
        raise ValueError("incomplete validation reuse program arguments")
    iterations = int(values["iterations"])
    if iterations <= 0:
        raise ValueError("invalid validation reuse iteration count")
    input_bytes = int(workload["actual_bytes"])
    work_bytes = input_bytes * iterations
    if "next-file" in values:
        next_iterations = int(values["next-iterations"])
        if next_iterations <= 0:
            raise ValueError("invalid validation reuse transition count")
        resources = workload["resolved_resources"]
        if not isinstance(resources, list):
            raise TypeError("invalid validation reuse resources")
        matches = [path for path in resources if path.name == values["next-file"]]
        if len(matches) != 1:
            raise ValueError("validation reuse transition input differs")
        work_bytes += matches[0].stat().st_size * next_iterations
    multiplier, remainder = divmod(work_bytes, input_bytes)
    if remainder or multiplier <= 0:
        raise ValueError("validation reuse work is not an exact input multiple")
    return multiplier


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
    classification: str,
    duration_ms: int,
    samples: int,
    warmups: int,
) -> str | None:
    try:
        report = read_json(path, MAX_OUTPUT_BYTES)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return f"invalid zebrac JSON: {error}"
    if not isinstance(report, dict) or report.get("schema_version") != 1:
        return "unexpected zebrac JSON schema"
    config = report.get("config")
    results = report.get("results")
    if not isinstance(config, dict) or not isinstance(results, list):
        return "incomplete zebrac JSON"
    if (
        config.get("duration_ms") != duration_ms
        or config.get("min_samples") != samples
        or config.get("max_samples") != samples
        or config.get("warmup") != warmups
    ):
        return "zebrac sampling configuration differs from request"
    expected_failures = classification == "not-well-formed"
    if config.get("allow_failures") is not expected_failures:
        return "zebrac failure policy differs from workload classification"
    if len(results) != len(commands):
        return "zebrac result count differs from target count"
    for index, result in enumerate(results):
        if not isinstance(result, dict):
            return f"invalid zebrac result at index {index}"
        if result.get("command") != commands[index]:
            return f"zebrac command differs at index {index}"
        sample_count = result.get("sample_count")
        failed_sample_count = result.get("failed_sample_count")
        if (
            type(sample_count) is not int
            or type(failed_sample_count) is not int
            or sample_count != samples
            or failed_sample_count < 0
            or failed_sample_count > sample_count
        ):
            return f"invalid zebrac sample counts at index {index}"
        if expected_failures and failed_sample_count != sample_count:
            return f"expected every malformed sample to fail at index {index}"
        if not expected_failures and failed_sample_count != 0:
            return f"valid workload has failed zebrac samples at index {index}"
    return None


def safe_name(value: str) -> str:
    return "".join(
        character if character.isalnum() or character in "-_" else "_"
        for character in value
    )


def host_information() -> dict[str, object]:
    cpu_model = "unknown"
    memory_kib = 0
    try:
        with Path("/proc/cpuinfo").open(encoding="utf-8") as stream:
            for line in stream:
                if line.startswith("model name"):
                    cpu_model = line.partition(":")[2].strip()
                    break
    except OSError:
        pass
    try:
        with Path("/proc/meminfo").open(encoding="utf-8") as stream:
            for line in stream:
                if line.startswith("MemTotal:"):
                    memory_kib = int(line.split()[1])
                    break
    except (OSError, ValueError):
        pass
    libc_name, libc_version = platform.libc_ver()
    affinity = (
        sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else []
    )
    governors: set[str] = set()
    for cpu in affinity:
        try:
            governors.add(
                Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor")
                .read_text(encoding="utf-8")
                .strip()
            )
        except OSError:
            pass
    perf_event_paranoid = None
    try:
        perf_event_paranoid = int(
            Path("/proc/sys/kernel/perf_event_paranoid")
            .read_text(encoding="utf-8")
            .strip()
        )
    except (OSError, ValueError):
        pass
    return {
        "system": platform.system(),
        "kernel": platform.release(),
        "machine": platform.machine(),
        "cpu_model": cpu_model,
        "logical_cpu_count": os.cpu_count(),
        "cpu_affinity": affinity,
        "cpu_governors": sorted(governors),
        "load_average": list(os.getloadavg()),
        "perf_event_paranoid": perf_event_paranoid,
        "memory_kib": memory_kib,
        "libc": libc_name,
        "libc_version": libc_version,
    }


def main() -> int:
    args = parse_args()
    if (
        args.max_bytes <= 0
        or args.max_bytes > MAX_WORKLOAD_BYTES
        or args.duration_ms <= 0
        or args.samples <= 1
        or args.samples > 10_000
        or args.warmups < 0
        or args.work_multiplier <= 0
        or args.timeout <= 0
        or args.max_output_bytes <= 0
        or args.max_output_bytes > MAX_OUTPUT_BYTES
        or not args.case
    ):
        print(
            "numeric limits must be positive, except warmups may be zero",
            file=sys.stderr,
        )
        return 64
    try:
        target_paths = args.targets or [args.default_targets]
        if len(target_paths) != len(args.bin_dir):
            raise ValueError("each --targets needs one --bin-dir in the same position")
        target_sets = list(zip(target_paths, args.bin_dir, strict=True))
        manifest_path = args.manifest.resolve()
        output_dir = args.output_dir.resolve()
        if not args.dry_run:
            early_outputs = {
                output_dir / "index.json",
                output_dir / "index.json.tmp",
            }
            direct_inputs = {
                manifest_path,
                *(path.resolve() for path in target_paths),
                *(path.resolve() for path in args.eligibility),
            }
            if (
                args.output_dir.is_symlink()
                or output_dir.is_relative_to(manifest_path.parent)
                or any(
                    output_dir.is_relative_to(bin_dir.resolve())
                    for bin_dir in args.bin_dir
                )
                or early_outputs & direct_inputs
            ):
                raise ValueError("output path overlaps an input or uses a symlink")
            output_dir.mkdir(parents=True, exist_ok=True)
            for path in early_outputs:
                path.unlink(missing_ok=True)
        targets: dict[str, Target] = {}
        for target_path, bin_dir in target_sets:
            current = read_targets(target_path, bin_dir.resolve())
            duplicates = targets.keys() & current.keys()
            if duplicates:
                raise ValueError(
                    "duplicate targets across manifests: "
                    + ",".join(sorted(duplicates))
                )
            targets.update(current)
        manifest_mtime_ns = manifest_path.stat().st_mtime_ns
        workloads, manifest_schema = read_workloads(manifest_path)
        eligibility: dict[tuple[str, str], list[Eligibility]] = {}
        for eligibility_path in args.eligibility:
            current = read_eligibility(eligibility_path)
            for pair, rows in current.items():
                existing = eligibility.setdefault(pair, [])
                if (
                    any(item.kind == "event" for item in [*existing, *rows])
                    and existing
                ):
                    raise ValueError(
                        "duplicate event eligibility across reports: " + "/".join(pair)
                    )
                if any(item.row == other.row for item in existing for other in rows):
                    raise ValueError(
                        "duplicate eligibility across reports: " + "/".join(pair)
                    )
                existing.extend(rows)
    except (OSError, KeyError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    selected_targets = set(args.target) if args.target else set(targets)
    unknown_targets = selected_targets.difference(targets)
    if unknown_targets:
        print("unknown targets: " + ",".join(sorted(unknown_targets)), file=sys.stderr)
        return 64
    selected_lanes = set(args.lane)
    unknown_lanes = selected_lanes.difference(
        target.work_lane for target in targets.values()
    )
    if unknown_lanes:
        print("unknown lanes: " + ",".join(sorted(unknown_lanes)), file=sys.stderr)
        return 64
    if selected_lanes and not any(
        target.name in selected_targets and target.work_lane in selected_lanes
        for target in targets.values()
    ):
        print("selected targets do not belong to the selected lanes", file=sys.stderr)
        return 64
    matched_workloads = [
        workload
        for workload in workloads.values()
        if any(
            fnmatch.fnmatchcase(workload["id"], pattern) for pattern in args.workload
        )
    ]
    if not matched_workloads:
        print("workload patterns matched nothing", file=sys.stderr)
        return 64

    groups: list[dict[str, object]] = []
    skipped: list[dict[str, str]] = []
    ineligible: list[dict[str, str]] = []
    try:
        used_stems: set[str] = set()
        for workload in matched_workloads:
            size = int(workload["actual_bytes"])
            if size > args.max_bytes:
                skipped.append({"workload": workload["id"], "reason": "max-bytes"})
                continue
            if any(
                target.name in selected_targets
                and target.work_lane == "validation-reuse"
                for target in targets.values()
            ) and args.work_multiplier != validation_reuse_multiplier(
                args.program_arg, workload
            ):
                raise ValueError(
                    f"{workload['id']}: validation reuse work multiplier differs"
                )
            if size * args.work_multiplier > 2**63 - 1:
                raise ValueError(f"{workload['id']}: work byte count exceeds i64")
            lanes = sorted({target.work_lane for target in targets.values()})
            for lane in lanes:
                if selected_lanes and lane not in selected_lanes:
                    continue
                candidates = [
                    target
                    for target in targets.values()
                    if target.name in selected_targets and target.work_lane == lane
                ]
                eligible: list[Target] = []
                input_models: list[str] = []
                for target in candidates:
                    if not target.executable.is_file() or not os.access(
                        target.executable, os.X_OK
                    ):
                        raise ValueError(
                            f"missing executable for {target.name}: {target.executable}"
                        )
                    pair = (target.name, workload["id"])
                    matched, reason, input_model = eligibility_match(
                        eligibility.get(pair),
                        target,
                        workload,
                        args.program_arg,
                        args.work_multiplier,
                        manifest_mtime_ns,
                    )
                    if matched:
                        eligible.append(target)
                        input_models.append(input_model)
                    else:
                        ineligible.append(
                            {
                                "target": target.name,
                                "workload": workload["id"],
                                "lane": lane,
                                "reason": reason,
                            }
                        )
                if not eligible:
                    continue
                commands = [
                    shlex.join(
                        [
                            str(target.executable),
                            *args.program_arg,
                            workload["resolved_path"],
                        ]
                    )
                    for target in eligible
                ]
                stem = safe_name(f"{workload['id']}--{lane}")
                if not stem or stem in used_stems:
                    raise ValueError(
                        f"ambiguous output name for {workload['id']}/{lane}"
                    )
                used_stems.add(stem)
                groups.append(
                    {
                        "workload": workload,
                        "lane": lane,
                        "targets": eligible,
                        "input_models": input_models,
                        "commands": commands,
                    }
                )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    blocking_ineligible = [
        item for item in ineligible if item["reason"] != "unsupported-feature"
    ]
    if blocking_ineligible:
        for item in blocking_ineligible:
            print(
                f"ineligible {item['target']}/{item['workload']} "
                f"[{item['lane']}]: {item['reason']}",
                file=sys.stderr,
            )
        print("selected work failed correctness qualification", file=sys.stderr)
        return 1
    if not groups:
        for item in ineligible:
            print(
                f"ineligible {item['target']}/{item['workload']} "
                f"[{item['lane']}]: {item['reason']}",
                file=sys.stderr,
            )
        print(
            "no correctness-passing target/workload groups were selected",
            file=sys.stderr,
        )
        return 1

    if args.dry_run:
        for group in groups:
            print(f"{group['workload']['id']} [{group['lane']}]")
            for target, command in zip(
                group["targets"], group["commands"], strict=True
            ):
                print(f"  {target.name}: {command}")
        for item in skipped:
            print(f"skip {item['workload']}: {item['reason']}")
        for item in ineligible:
            print(
                f"ineligible {item['target']}/{item['workload']} "
                f"[{item['lane']}]: {item['reason']}"
            )
        return 0

    zebrac = resolve_zebrac(args.zebrac)
    if zebrac is None:
        print("zebrac not found on PATH; pass --zebrac PATH", file=sys.stderr)
        return 1
    if not zebrac.is_file() or not os.access(zebrac, os.X_OK):
        print(f"missing executable Zebrac: {zebrac}", file=sys.stderr)
        return 1
    if args.output_dir.is_symlink() or output_dir.is_relative_to(manifest_path.parent):
        print("output directory overlaps the corpus or is a symlink", file=sys.stderr)
        return 1
    if any(output_dir.is_relative_to(bin_dir.resolve()) for bin_dir in args.bin_dir):
        print("output directory overlaps a binary directory", file=sys.stderr)
        return 1

    try:
        participating_targets = {
            target.name for group in groups for target in group["targets"]
        }
        selected_binary_metadata = {}
        for target in targets.values():
            if target.name not in participating_targets:
                continue
            binary_stat = target.executable.stat()
            selected_binary_metadata[target.name] = {
                "path": str(target.executable),
                "size": binary_stat.st_size,
                "mtime_ns": binary_stat.st_mtime_ns,
                "processor_class": target.processor_class,
                "lane": target.work_lane,
                "input_model": target.input_model,
            }
        for group in groups:
            workload = group["workload"]
            for target, expected_input_model in zip(
                group["targets"], group["input_models"], strict=True
            ):
                matched, reason, input_model = eligibility_match(
                    eligibility.get((target.name, workload["id"])),
                    target,
                    workload,
                    args.program_arg,
                    args.work_multiplier,
                    manifest_mtime_ns,
                )
                if not matched or input_model != expected_input_model:
                    raise ValueError(
                        f"qualification changed for {target.name}/{workload['id']}: "
                        f"{reason}"
                    )
        eligibility_metadata = {}
        for items in eligibility.values():
            for item in items:
                if item.path in eligibility_metadata:
                    continue
                eligibility_stat = item.path.stat()
                if eligibility_stat.st_mtime_ns != item.mtime_ns:
                    raise ValueError(
                        f"eligibility changed before measurement: {item.path}"
                    )
                eligibility_metadata[item.path] = {
                    "path": str(item.path),
                    "size": eligibility_stat.st_size,
                    "mtime_ns": item.mtime_ns,
                }
        manifest_stat = manifest_path.stat()
        zebrac_stat = zebrac.stat()
        input_metadata = {
            "manifest": {
                "path": str(manifest_path),
                "size": manifest_stat.st_size,
                "mtime_ns": manifest_mtime_ns,
            },
            "zebrac": {
                "path": str(zebrac),
                "size": zebrac_stat.st_size,
                "mtime_ns": zebrac_stat.st_mtime_ns,
            },
        }
        resource_metadata = {
            path: {
                "path": str(path),
                "size": path.stat().st_size,
                "mtime_ns": path.stat().st_mtime_ns,
            }
            for group in groups
            for path in group["workload"]["resolved_resources"]
        }
        if manifest_stat.st_mtime_ns != manifest_mtime_ns:
            raise ValueError("corpus manifest changed before measurement")
        target_manifest_mtimes = {
            target.manifest: target.manifest_mtime_ns for target in targets.values()
        }
        target_set_metadata = []
        for target_path, bin_dir in target_sets:
            resolved_target_path = target_path.resolve()
            target_stat = resolved_target_path.stat()
            if target_stat.st_mtime_ns != target_manifest_mtimes[resolved_target_path]:
                raise ValueError(
                    f"target manifest changed before measurement: "
                    f"{resolved_target_path}"
                )
            target_set_metadata.append(
                {
                    "targets_manifest": {
                        "path": str(resolved_target_path),
                        "size": target_stat.st_size,
                        "mtime_ns": target_stat.st_mtime_ns,
                    },
                    "bin_dir": str(bin_dir.resolve()),
                }
            )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    planned_outputs = {output_dir / "index.json", output_dir / "index.json.tmp"}
    for group in groups:
        workload = group["workload"]
        stem = safe_name(f"{workload['id']}--{group['lane']}")
        planned_outputs.update(
            {
                output_dir / f"{stem}.json",
                output_dir / f"{stem}.stdout.txt",
                output_dir / f"{stem}.stderr.txt",
            }
        )
    input_paths = {
        manifest_path,
        zebrac,
        *eligibility_metadata,
        *(target.manifest for target in targets.values()),
        *(target.executable for group in groups for target in group["targets"]),
        *(Path(group["workload"]["resolved_path"]) for group in groups),
        *resource_metadata,
    }
    if planned_outputs & input_paths:
        print("output path overlaps an input", file=sys.stderr)
        return 1
    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        for path in planned_outputs:
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
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 1

    index: dict[str, object] = {
        "schema": "z-xml-zebrac-matrix-v4",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "manifest": {**input_metadata["manifest"], "schema": manifest_schema},
        "eligibility": [
            eligibility_metadata[path] for path in sorted(eligibility_metadata, key=str)
        ],
        "zebrac": {**input_metadata["zebrac"], "version": version_text},
        "target_sets": target_set_metadata,
        "source": source_information(Path(__file__).resolve().parents[2]),
        "host": host_information(),
        "target_binaries": selected_binary_metadata,
        "resources": [
            resource_metadata[path] for path in sorted(resource_metadata, key=str)
        ],
        "measurement_case": args.case,
        "program_arguments": args.program_arg,
        "work_multiplier": args.work_multiplier,
        "sampling": {
            "duration_ms": args.duration_ms,
            "samples": args.samples,
            "warmups": args.warmups,
            "timeout_seconds": args.timeout,
        },
        "runs": [],
        "skipped": skipped,
        "ineligible": ineligible,
    }
    had_error = False
    for group in groups:
        workload = group["workload"]
        lane = str(group["lane"])
        stem = safe_name(f"{workload['id']}--{lane}")
        json_path = output_dir / f"{stem}.json"
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
            f"--json={json_path}",
        ]
        if workload["classification"] == "not-well-formed":
            command.append("--allow-failures")
        command.append("--")
        command.extend(group["commands"])
        try:
            completed = run_process(command, args.timeout, args.max_output_bytes)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(
                f"Zebrac failed for {workload['id']} [{lane}]: {error}",
                file=sys.stderr,
            )
            had_error = True
            break
        stdout_path = output_dir / f"{stem}.stdout.txt"
        stderr_path = output_dir / f"{stem}.stderr.txt"
        try:
            stdout_path.write_text(completed[1], encoding="utf-8")
            stderr_path.write_text(completed[2], encoding="utf-8")
        except OSError as error:
            print(
                f"cannot write Zebrac output for {workload['id']} [{lane}]: {error}",
                file=sys.stderr,
            )
            had_error = True
            break
        run = {
            "result": "pass",
            "workload": workload["id"],
            "input": {
                "path": workload["resolved_path"],
                "size": int(workload["actual_bytes"]),
                "mtime_ns": int(workload["source_mtime_ns"]),
            },
            "resources": [
                resource_metadata[path] for path in workload["resolved_resources"]
            ],
            "bytes": int(workload["actual_bytes"]),
            "work_bytes": int(workload["actual_bytes"]) * args.work_multiplier,
            "classification": workload["classification"],
            "lane": lane,
            "targets": [target.name for target in group["targets"]],
            "input_models": group["input_models"],
            "commands": group["commands"],
            "zebrac_json": json_path.name,
            "stdout": stdout_path.name,
            "stderr": stderr_path.name,
            "status": completed[0],
        }
        result_error = None
        if completed[0] == 0 and not completed[3] and not completed[4]:
            try:
                if (
                    not json_path.is_file()
                    or json_path.stat().st_size > args.max_output_bytes
                ):
                    result_error = "zebrac JSON is missing or exceeds the limit"
                else:
                    result_error = validate_zebrac_results(
                        json_path,
                        group["commands"],
                        workload["classification"],
                        args.duration_ms,
                        args.samples,
                        args.warmups,
                    )
            except OSError as error:
                result_error = f"cannot inspect zebrac JSON: {error}"
        if (
            completed[0] != 0
            or completed[3]
            or completed[4]
            or result_error is not None
        ):
            had_error = True
            if completed[3]:
                reason = "timeout"
            elif completed[4]:
                reason = "output-limit"
            else:
                reason = result_error or f"status-{completed[0]}"
            print(
                f"Zebrac failed for {workload['id']} [{lane}]: {reason}",
                file=sys.stderr,
            )
            break
        else:
            index["runs"].append(run)
            print(f"measured {workload['id']} [{lane}]")
    if had_error:
        (output_dir / "index.json").unlink(missing_ok=True)
        return 1

    try:
        if manifest_path.stat().st_mtime_ns != manifest_mtime_ns:
            raise ValueError("corpus manifest changed during measurement")
        if (
            zebrac.stat().st_size != input_metadata["zebrac"]["size"]
            or zebrac.stat().st_mtime_ns != input_metadata["zebrac"]["mtime_ns"]
        ):
            raise ValueError("Zebrac changed during measurement")
        checked_manifests: set[Path] = set()
        for target in targets.values():
            if target.manifest in checked_manifests:
                continue
            checked_manifests.add(target.manifest)
            if target.manifest.stat().st_mtime_ns != target.manifest_mtime_ns:
                raise ValueError(
                    f"target manifest changed during measurement: {target.manifest}"
                )
        for metadata in selected_binary_metadata.values():
            path = Path(str(metadata["path"]))
            if (
                path.stat().st_size != metadata["size"]
                or path.stat().st_mtime_ns != metadata["mtime_ns"]
            ):
                raise ValueError(f"target changed during measurement: {path}")
        for metadata in eligibility_metadata.values():
            path = Path(str(metadata["path"]))
            if (
                path.stat().st_size != metadata["size"]
                or path.stat().st_mtime_ns != metadata["mtime_ns"]
            ):
                raise ValueError(f"eligibility changed during measurement: {path}")
        for group in groups:
            workload = group["workload"]
            path = Path(workload["resolved_path"])
            if path.stat().st_size != int(
                workload["actual_bytes"]
            ) or path.stat().st_mtime_ns != int(workload["source_mtime_ns"]):
                raise ValueError(f"workload changed during measurement: {path}")
        for metadata in resource_metadata.values():
            path = Path(str(metadata["path"]))
            if (
                path.stat().st_size != metadata["size"]
                or path.stat().st_mtime_ns != metadata["mtime_ns"]
            ):
                raise ValueError(f"resource changed during measurement: {path}")
        temporary = output_dir / "index.json.tmp"
        temporary.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
        temporary.replace(output_dir / "index.json")
    except (OSError, ValueError) as error:
        (output_dir / "index.json").unlink(missing_ok=True)
        (output_dir / "index.json.tmp").unlink(missing_ok=True)
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
