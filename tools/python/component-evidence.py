#!/usr/bin/env python3
"""Run component qualification, baseline, and matched-peer evidence paths.

Qualification uses the existing generators and semantic checkers. Baseline and
comparison use the existing Zebrac wrappers and summary parser, so this command
does not define another XML oracle or timing format. Workloads, targets, and
sampling stay explicit because later component stages own their final lanes.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from qualification_io import decode_json_object, publish_tsv, read_limited
from zebrac_measurement import file_information, source_information

COMPONENTS = ("reader", "document", "writer", "dtd", "validation")
QUALIFICATION_SCHEMA = "z-xml-component-qualification-v1"
STATUS_FIELDS = ["component", "operation", "status", "reason"]
STATUS_SCHEMA = "z-xml-component-status-v1"
CONTROL_FIELDS = [
    "component",
    "workload",
    "target",
    "side",
    "samples",
    "wall_mean_ns",
    "wall_cv_pct",
    "instructions_mean",
    "wall_drift_pct",
    "instructions_drift_pct",
]
CONTROL_SCHEMA = "z-xml-component-controls-v1"
METRIC_FIELDS = [
    "component",
    "workload",
    "target",
    "lane",
    "input_model",
    "program_arguments",
    "cache_state",
    "work_bytes",
    "wall_mean_ns",
    "wall_max_cv_pct",
    "wall_drift_pct",
    "throughput_mib_s",
    "peak_rss_mean_bytes",
    "instructions_mean",
    "instructions_drift_pct",
    "cycles_mean",
    "cache_misses_mean",
    "branch_misses_mean",
    "samples",
    "failed_samples",
    "allocator_operations",
    "owned_peak_bytes",
    "retained_bytes",
    "evidence",
]
METRIC_SCHEMA = "z-xml-component-metrics-v1"
MAX_CONTROL_BYTES = 16 * 1024 * 1024
QUICK_MAX_BYTES = 16 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)

    qualify = subparsers.add_parser("qualify")
    qualify.add_argument("component", choices=COMPONENTS)
    qualify.add_argument("--full", action="store_true")
    qualify.add_argument("--artifact-root", type=Path)
    qualify.add_argument("--result-root", type=Path)
    qualify.add_argument("--timeout", type=float, default=600.0)
    qualify.add_argument("--dry-run", action="store_true")

    baseline = subparsers.add_parser("baseline")
    add_measurement_args(baseline, comparison=False)

    compare = subparsers.add_parser("compare")
    add_measurement_args(compare, comparison=True)
    return parser.parse_args()


def add_measurement_args(parser: argparse.ArgumentParser, comparison: bool) -> None:
    parser.add_argument("component", choices=COMPONENTS)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--qualification-index", type=Path)
    parser.add_argument("--eligibility", type=Path, action="append", default=[])
    parser.add_argument("--targets", type=Path, action="append", default=[])
    parser.add_argument("--bin-dir", type=Path, action="append", default=[])
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--workload")
    parser.add_argument("--program-arg", action="append", default=[])
    parser.add_argument("--result-root", type=Path)
    parser.add_argument("--duration-ms", type=int, default=5000)
    parser.add_argument("--samples", type=int, default=20 if not comparison else 10)
    parser.add_argument("--warmups", type=int, default=5 if not comparison else 3)
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--max-output-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--zebrac", type=Path)
    parser.add_argument("--not-entered")
    parser.add_argument("--dry-run", action="store_true")
    if comparison:
        parser.add_argument("--lane", action="append", default=[])
        parser.add_argument("--baseline", action="append", default=[])
        parser.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024)
        parser.add_argument("--no-eligible-peer")
    else:
        parser.add_argument("--work-bytes", type=int)
        parser.set_defaults(lane=[])


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_result_root(root: Path, component: str) -> Path:
    return root / "data" / "results" / f"{component}-baseline"


def run(command: list[str], timeout: float, dry_run: bool) -> None:
    if dry_run:
        print(shlex.join(command))
        return
    completed = subprocess.run(command, check=False, timeout=timeout)
    if completed.returncode != 0:
        raise ValueError(
            f"command returned status {completed.returncode}: {shlex.join(command)}"
        )


def zig_build(
    root: Path,
    step: str,
    artifact_root: Path,
    timeout: float,
    dry_run: bool,
) -> list[str]:
    command = [
        "zig",
        "build",
        "--build-file",
        str(root / "tools" / "build.zig"),
        step,
        "-Dtarget=x86_64-linux",
        "-Doptimize=ReleaseFast",
        "--prefix",
        str(artifact_root),
        "--cache-dir",
        str(artifact_root / "cache"),
    ]
    run(command, timeout, dry_run)
    return command


def python_command(root: Path, name: str, *arguments: object) -> list[str]:
    return [
        sys.executable,
        str(root / "tools" / "python" / name),
        *(str(argument) for argument in arguments),
    ]


def check_tsv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    lines = read_limited(path).decode("utf-8").splitlines()
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    if rows.fieldnames is None:
        raise ValueError(f"{path}: missing TSV header")
    values = list(rows)
    if not values:
        raise ValueError(f"{path}: empty TSV report")
    verdicts = {row.get("verdict") for row in values}
    if "pass" not in verdicts or verdicts.difference({"pass", "unsupported-feature"}):
        raise ValueError(f"{path}: contains failed semantic rows")
    return list(rows.fieldnames), values


def merge_tsv(inputs: list[Path], output: Path) -> int:
    fieldnames: list[str] | None = None
    combined: list[dict[str, str]] = []
    identities: set[tuple[str, ...]] = set()
    for path in inputs:
        current_fields, rows = check_tsv(path)
        if fieldnames is None:
            fieldnames = current_fields
        elif fieldnames != current_fields:
            raise ValueError("qualification reports use different columns")
        for row in rows:
            identity = tuple(row[field] for field in fieldnames)
            if identity in identities:
                raise ValueError(f"{path}: duplicate qualification row")
            identities.add(identity)
            combined.append(row)
    if fieldnames is None:
        raise ValueError("no qualification reports")
    publish_tsv(output, fieldnames, combined)
    return len(combined)


def qualification_commands(
    root: Path,
    component: str,
    full: bool,
    bin_dir: Path,
    staging: Path,
) -> tuple[str, list[list[str]], list[Path]]:
    tools = root / "tools"
    generated = root / "data" / "generated"
    commands: list[list[str]] = []
    reports: list[Path] = []
    report_name = "qualification.tsv" if full else "quick-qualification.tsv"
    main_report = staging / report_name

    if component == "reader":
        corpus = (
            generated / "z-xml-generated-v3-reader"
            if full
            else generated / "z-xml-generated-v3-persistent"
        )
        verify = python_command(
            root,
            "generate-benchmark-corpus.py",
            "--output-dir",
            corpus,
            *(
                ["--plan", root / "bench" / "full.tsv", "--no-depth"]
                if full
                else [
                    "--sizes-kib",
                    "1,16,64,256",
                    "--no-rejection",
                    "--depths",
                    "16,256",
                ]
            ),
            "--check",
        )
        namespace = generated / "z-xml-namespace-benchmark-v1"
        commands.extend(
            [
                verify,
                python_command(
                    root,
                    "generate-namespace-benchmark.py",
                    "--output-dir",
                    namespace,
                    "--check",
                ),
            ]
        )
        general_report = main_report
        namespace_report = staging / "qualification-namespace.tsv"
        general = python_command(
            root,
            "check-generated-corpus.py",
            "--manifest",
            corpus / "manifest.tsv",
            "--targets",
            tools / "targets.tsv",
            "--bin-dir",
            bin_dir,
            "--target",
            "z-xml-raw-reject",
            "--target",
            "z-xml-namespace-reject",
            "--results",
            general_report,
        )
        namespace_check = python_command(
            root,
            "check-generated-persistent.py",
            "--manifest",
            namespace / "manifest.tsv",
            "--targets",
            tools / "persistent-targets.tsv",
            "--program",
            bin_dir / "z-xml-ns-persistent",
            "--engine",
            "z-xml-ns",
            "--target",
            "z-xml-ns-persistent",
            "--namespace",
            "--input",
            "stream",
            "--consumer",
            "full",
            "--chunk-bytes",
            "65536",
            "--iterations",
            "1",
            "--results",
            namespace_report,
        )
        if not full:
            general.extend(("--max-bytes", str(QUICK_MAX_BYTES)))
            namespace_check.extend(("--max-bytes", str(QUICK_MAX_BYTES)))
        commands.extend((general, namespace_check))
        reports.extend((general_report, namespace_report))
    elif component == "document":
        corpus = (
            generated / "z-xml-generated-v3-document"
            if full
            else generated / "z-xml-generated-v3-persistent"
        )
        namespace = generated / (
            "z-xml-namespace-document-v1" if full else "z-xml-namespace-benchmark-v1"
        )
        verify = python_command(
            root,
            "generate-benchmark-corpus.py",
            "--output-dir",
            corpus,
            *(
                [
                    "--sizes-mib",
                    "64",
                    "--shapes",
                    "attributes-varied,mixed,text",
                    "--no-rejection",
                    "--depths",
                    "256",
                ]
                if full
                else [
                    "--sizes-kib",
                    "1,16,64,256",
                    "--no-rejection",
                    "--depths",
                    "16,256",
                ]
            ),
            "--check",
        )
        namespace_verify = python_command(
            root,
            "generate-namespace-benchmark.py",
            "--output-dir",
            namespace,
        )
        if full:
            namespace_verify.extend(("--sizes-kib", "65536"))
        namespace_verify.append("--check")
        commands.extend((verify, namespace_verify))
        operation_reports: list[Path] = []
        for operation in ("construction", "traversal"):
            for family, manifest, namespace_flag in (
                ("general", corpus / "manifest.tsv", False),
                ("namespace", namespace / "manifest.tsv", True),
            ):
                report = staging / f"document-{family}-{operation}.tsv"
                command = python_command(
                    root,
                    "check-generated-corpus.py",
                    "--manifest",
                    manifest,
                    "--targets",
                    tools / "document-targets.tsv",
                    "--bin-dir",
                    bin_dir,
                    "--target",
                    "z-xml-document",
                    "--document-oracle",
                    bin_dir / "z-xml-tree",
                    "--document-operation",
                    operation,
                    "--results",
                    report,
                )
                if namespace_flag:
                    command.extend(("--namespace", "--shape", "namespace-churn"))
                else:
                    for shape in ("attributes-varied", "mixed", "text", "deep"):
                        command.extend(("--shape", shape))
                if not full:
                    command.extend(("--max-bytes", str(QUICK_MAX_BYTES)))
                commands.append(command)
                operation_reports.append(report)
        reports.extend(operation_reports)
        if full:
            repeat_manifest = generated / "z-xml-document-repeat-v1.tsv"
            repeat_report = staging / "document-repeat.tsv"
            commands.extend(
                (
                    python_command(root, "generate-document-repeat.py", "--check"),
                    python_command(
                        root,
                        "check-document-repeat.py",
                        "--manifest",
                        repeat_manifest,
                        "--targets",
                        tools / "document-targets.tsv",
                        "--bin-dir",
                        bin_dir,
                        "--results",
                        repeat_report,
                    ),
                )
            )
    elif component == "writer":
        commands.append(python_command(root, "check-shape-matrix.py"))
        reports.append(main_report)
    elif component == "dtd":
        manifest = generated / "z-xml-dtd-generated-v1" / "manifest.tsv"
        report = staging / report_name
        commands.append(
            python_command(
                root,
                "generate-dtd-benchmark.py",
                "--output-dir",
                manifest.parent,
                "--check",
            )
        )
        command = python_command(
            root,
            "check-dtd-benchmark.py",
            "--manifest",
            manifest,
            "--targets",
            tools / "dtd-targets.tsv",
            "--bin-dir",
            bin_dir,
            "--results",
            report,
        )
        if not full:
            for workload in (
                "syntax-64k",
                "recursive-entity",
                "external-unavailable",
                "external-failure",
                "dtd-bytes-at",
                "dtd-bytes-over",
                "expansion-at",
                "expansion-over",
                "external-bytes-at",
                "external-bytes-over",
            ):
                command.extend(("--workload", workload))
        commands.append(command)
        reports.append(report)
    else:
        fresh_manifest = generated / "z-xml-validation-generated-v1" / "manifest.tsv"
        reuse_manifest = generated / "z-xml-validation-reuse-v1" / "manifest.tsv"
        fresh_report = staging / report_name
        reuse_report = staging / (
            "qualification-reuse.tsv" if full else "quick-qualification-reuse.tsv"
        )
        commands.extend(
            (
                python_command(
                    root,
                    "generate-validation-benchmark.py",
                    "--output-dir",
                    fresh_manifest.parent,
                    "--check",
                ),
                python_command(
                    root,
                    "generate-validation-reuse.py",
                    "--output-dir",
                    reuse_manifest.parent,
                    "--check",
                ),
            )
        )
        fresh = python_command(
            root,
            "check-validation-benchmark.py",
            "--manifest",
            fresh_manifest,
            "--targets",
            tools / "validation-targets.tsv",
            "--bin-dir",
            bin_dir,
            "--results",
            fresh_report,
        )
        reuse = python_command(
            root,
            "check-validation-reuse.py",
            "--manifest",
            reuse_manifest,
            "--targets",
            tools / "validation-targets.tsv",
            "--bin-dir",
            bin_dir,
            "--results",
            reuse_report,
        )
        if not full:
            for workload in (
                "findings-64k",
                "nondeterministic",
                "syntax-64k",
                "external-unavailable",
                "content-position-limit",
            ):
                fresh.extend(("--workload", workload))
            for workload in ("validation-reuse-small", "validation-reuse-invalid"):
                reuse.extend(("--workload", workload))
        commands.extend((fresh, reuse))
        reports.extend((fresh_report, reuse_report))
    return report_name, commands, reports


def writer_rows(
    root: Path,
    bin_dir: Path,
    full: bool,
    timeout: float,
    dry_run: bool,
) -> tuple[list[dict[str, object]], list[list[str]]]:
    manifest = root / "bench" / "shapes.tsv"
    lines = read_limited(manifest).decode("utf-8").splitlines()
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    if rows.fieldnames is None:
        raise ValueError(f"{manifest}: missing shape header")
    selections: list[tuple[str, str, str]] = []
    quick_values = {
        "writer-attributes": "16",
        "writer-unchanged-text": "16k",
        "writer-escaped-text": "16k",
        "writer-fragmented-text": "16k",
        "writer-namespace-depth": "16",
        "writer-short-sink": "1k",
        "writer-repeated-documents": "16",
    }
    for row in rows:
        if row["lane"] != "writer" or row["status"] != "ready":
            continue
        shape = row["id"]
        values = row["size_plan"].split(":", 1)[-1].split(",")
        sinks = row["input_models"].split(",")
        if full:
            selections.extend(
                (shape, value, sink) for value in values for sink in sinks
            )
        else:
            value = quick_values.get(shape)
            if value is None or value not in values:
                raise ValueError(f"{manifest}: missing quick Writer value for {shape}")
            selections.extend((shape, value, sink) for sink in sinks)
    if set(quick_values).difference(shape for shape, _, _ in selections):
        raise ValueError(f"{manifest}: incomplete Writer shape coverage")
    program = bin_dir / "z-xml-writer"
    result_rows: list[dict[str, object]] = []
    commands: list[list[str]] = []
    for shape, value, sink in selections:
        command = [str(program), "--verify", str(manifest), shape, value, sink]
        commands.append(command)
        if dry_run:
            print(shlex.join(command))
            continue
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if (
            completed.returncode != 0
            or completed.stderr
            or completed.stdout.count("\n") != 1
        ):
            raise ValueError(f"Writer qualification failed: {shlex.join(command)}")
        result = decode_json_object(completed.stdout)
        phase = (
            result.get("primary") if shape == "writer-repeated-documents" else result
        )
        integer_fields = (
            "output_bytes",
            "sink_accepted_bytes",
            "writer_live_bytes_after_deinit",
            "writer_allocator_allocs",
            "writer_allocator_resizes",
            "writer_allocator_remaps",
            "writer_peak_live_bytes",
            "writer_final_retained_capacity_bytes",
        )
        if (
            not isinstance(phase, dict)
            or result.get("shape") != shape
            or result.get("sink") != sink
            or result.get("verified") is not True
            or phase.get("value") != value
            or any(
                type(phase.get(field)) is not int or phase[field] < 0
                for field in integer_fields
            )
            or phase.get("output_bytes") != phase.get("sink_accepted_bytes")
            or phase.get("writer_live_bytes_after_deinit") != 0
        ):
            raise ValueError(f"Writer result contract failed: {shape}/{value}/{sink}")
        result_rows.append(
            {
                "target": "z-xml-writer",
                "workload": shape,
                "classification": "benchmark-valid",
                "verdict": "pass",
                "work_lane": "writer",
                "input_model": "manifest-selected",
                "program_args": f"{value} {sink}",
                "status": 0,
                "output_bytes": phase["output_bytes"],
                "sink_accepted_bytes": phase["sink_accepted_bytes"],
                "writer_live_bytes_after_deinit": 0,
                "allocator_operations": phase["writer_allocator_allocs"]
                + phase["writer_allocator_resizes"]
                + phase["writer_allocator_remaps"],
                "owned_peak_bytes": phase["writer_peak_live_bytes"],
                "retained_bytes": phase["writer_final_retained_capacity_bytes"],
            }
        )
    return result_rows, commands


def publish_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def qualify(args: argparse.Namespace) -> int:
    root = project_root()
    result_root = (
        args.result_root or default_result_root(root, args.component)
    ).resolve()
    artifact_root = (
        args.artifact_root or root / "tmp" / "component-evidence" / args.component
    ).resolve()
    if args.timeout <= 0:
        raise ValueError("timeout must be positive")
    if result_root.is_relative_to(root) and not result_root.is_relative_to(
        root / "data" / "results"
    ):
        raise ValueError(
            "component result root must be under data/results or outside the repository"
        )
    if artifact_root.is_relative_to(root) and not artifact_root.is_relative_to(
        root / "tmp"
    ):
        raise ValueError("artifact root must be under tmp or outside the repository")
    if (
        artifact_root == result_root
        or artifact_root.is_relative_to(result_root)
        or result_root.is_relative_to(artifact_root)
    ):
        raise ValueError("artifact root overlaps the component result root")
    build_steps = {
        "reader": "tools",
        "document": "tree-adapter",
        "writer": "writer-adapter",
        "dtd": "corpus-adapters",
        "validation": "tools",
    }
    scope = "full" if args.full else "quick"
    final_dir = result_root if args.full else result_root / "evidence" / "quick"
    if args.dry_run:
        staging = result_root / "evidence" / f"{scope}-dry-run"
    else:
        final_dir.mkdir(parents=True, exist_ok=True)
        (final_dir / "qualification-index.json").unlink(missing_ok=True)
        staging = Path(
            tempfile.mkdtemp(prefix=f".{args.component}-{scope}-", dir=result_root)
        )
    commands: list[list[str]] = []
    initial_source = source_information(root)
    try:
        commands.append(
            zig_build(
                root,
                build_steps[args.component],
                artifact_root,
                args.timeout,
                args.dry_run,
            )
        )
        report_name, selected, reports = qualification_commands(
            root, args.component, args.full, artifact_root / "bin", staging
        )
        commands.extend(selected)
        for command in selected:
            run(command, args.timeout, args.dry_run)
        writer_qualification: list[dict[str, object]] = []
        if args.component == "writer":
            writer_qualification, writer_commands = writer_rows(
                root,
                artifact_root / "bin",
                args.full,
                args.timeout,
                args.dry_run,
            )
            commands.extend(writer_commands)
        if args.dry_run:
            return 0
        if args.component == "writer":
            fields = [
                "target",
                "workload",
                "classification",
                "verdict",
                "work_lane",
                "input_model",
                "program_args",
                "status",
                "output_bytes",
                "sink_accepted_bytes",
                "writer_live_bytes_after_deinit",
                "allocator_operations",
                "owned_peak_bytes",
                "retained_bytes",
            ]
            publish_tsv(staging / report_name, fields, writer_qualification)
            reports = [staging / report_name]
        elif len(reports) > 1 and args.component == "document":
            namespace_reports = [
                report for report in reports if "namespace" in report.name
            ]
            general_reports = [
                report for report in reports if "namespace" not in report.name
            ]
            namespace_report = staging / "qualification-namespace.tsv"
            merge_tsv(general_reports, staging / report_name)
            merge_tsv(namespace_reports, namespace_report)
            reports = [staging / report_name, namespace_report]
            if args.component == "document" and args.full:
                reports.append(staging / "document-repeat.tsv")
        checked = []
        for report in reports:
            _, rows = check_tsv(report)
            checked.append({"file": report.name, "rows": len(rows)})
        for report in reports:
            if report.name == report_name and report == staging / report_name:
                continue
            destination = final_dir / report.name
            shutil.copyfile(report, destination)
        shutil.copyfile(staging / report_name, final_dir / report_name)
        artifacts = [
            file_information(path)
            for path in sorted((artifact_root / "bin").iterdir())
            if path.is_file() and os.access(path, os.X_OK)
        ]
        final_source = source_information(root)
        if final_source != initial_source:
            raise ValueError("source state changed during qualification")
        metadata = {
            "schema": QUALIFICATION_SCHEMA,
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "component": args.component,
            "scope": scope,
            "source": final_source,
            "target": "x86_64-linux",
            "optimize": "ReleaseFast",
            "artifact_root": str(artifact_root),
            "artifacts": artifacts,
            "commands": commands,
            "reports": checked,
        }
        publish_json(final_dir / "qualification-index.json", metadata)
        print(
            f"qualified {args.component} ({scope}): "
            f"{sum(item['rows'] for item in checked)} rows"
        )
        return 0
    finally:
        if not args.dry_run:
            shutil.rmtree(staging, ignore_errors=True)


def target_rows(path: Path) -> list[dict[str, str]]:
    lines = read_limited(path).decode("utf-8").splitlines()
    if len(lines) < 3 or not lines[0].startswith("#") or not lines[1].startswith("#"):
        raise ValueError(f"{path}: incomplete target declarations")
    fieldnames = lines[1].removeprefix("#").strip().split("\t")
    rows = csv.DictReader(
        (line for line in lines[2:] if not line.startswith("#")),
        fieldnames=fieldnames,
        delimiter="\t",
    )
    required = {"name", "executable", "work_lane", "input_model"}
    if rows.fieldnames is None or required.difference(rows.fieldnames):
        raise ValueError(f"{path}: incomplete target declarations")
    return list(rows)


def selected_lane(component: str, targets: list[Path], selected: list[str]) -> str:
    allowed = {
        "reader": {"event", "event-persistent", "event-persistent-namespace"},
        "document": {"dom", "document-repeat"},
        "writer": {"writer"},
        "dtd": {"dtd", "dtd-control"},
        "validation": {"validation", "validation-reuse"},
    }[component]
    found: dict[str, str] = {}
    for path in targets:
        for row in target_rows(path):
            if row["name"] in selected:
                found[row["name"]] = row["work_lane"]
    missing = set(selected).difference(found)
    if missing:
        raise ValueError(
            "selected targets are not declared: " + ",".join(sorted(missing))
        )
    invalid = {name: lane for name, lane in found.items() if lane not in allowed}
    if invalid:
        raise ValueError(
            "selected targets belong to another component: "
            + ",".join(f"{name}={lane}" for name, lane in sorted(invalid.items()))
        )
    lanes = set(found.values())
    if len(lanes) != 1:
        raise ValueError("selected targets do not share one work lane")
    return next(iter(lanes))


def safe_name(value: str) -> str:
    safe = "".join(byte if byte.isalnum() or byte in "-_" else "-" for byte in value)
    if not safe or safe in {".", ".."}:
        raise ValueError("invalid workload name")
    return safe


def write_status(
    result_root: Path,
    component: str,
    operation: str,
    status: str,
    reason: str,
) -> None:
    if not reason.strip():
        raise ValueError("status reason must not be empty")
    path = result_root / f"{operation}-status.tsv"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        stream.write(f"# {STATUS_SCHEMA}\n")
        writer = csv.DictWriter(
            stream, STATUS_FIELDS, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerow(
            {
                "component": component,
                "operation": operation,
                "status": status,
                "reason": reason.strip(),
            }
        )
    temporary.replace(path)


def clear_measurement_result(result_root: Path, operation: str) -> None:
    names = (
        ("controls.tsv", "metrics.tsv") if operation == "baseline" else ("peers.tsv",)
    )
    for name in names:
        (result_root / name).unlink(missing_ok=True)


def validate_measurement_args(args: argparse.Namespace, comparison: bool) -> str:
    if args.not_entered is not None and not args.not_entered.strip():
        raise ValueError("--not-entered requires a reason")
    if comparison and args.no_eligible_peer is not None:
        if not args.no_eligible_peer.strip():
            raise ValueError("--no-eligible-peer requires a reason")
        if args.not_entered is not None:
            raise ValueError("status options cannot be combined")
    if args.not_entered is not None:
        if args.component not in {"dtd", "validation"}:
            raise ValueError("--not-entered is only valid for DTD or validation")
        return "not-entered"
    if comparison and args.no_eligible_peer is not None:
        return "no-eligible-peer"
    required = {
        "manifest": args.manifest,
        "qualification-index": args.qualification_index,
        "eligibility": args.eligibility,
        "targets": args.targets,
        "bin-dir": args.bin_dir,
        "target": args.target,
        "workload": args.workload,
    }
    if comparison:
        required["baseline"] = args.baseline
    missing = [name for name, value in required.items() if not value]
    if missing:
        raise ValueError("missing measurement arguments: " + ",".join(missing))
    if len(args.targets) != len(args.bin_dir):
        raise ValueError("each --targets requires one --bin-dir")
    if not comparison and any(
        len(values) != 1
        for values in (args.eligibility, args.targets, args.bin_dir, args.target)
    ):
        raise ValueError("baseline requires one eligibility, target set, and target")
    if not comparison and args.work_bytes is not None and args.work_bytes <= 0:
        raise ValueError("--work-bytes must be positive")
    return selected_lane(args.component, args.targets, args.target)


def check_full_qualification(args: argparse.Namespace, root: Path) -> None:
    index_path = args.qualification_index.resolve()
    value = json.loads(read_limited(index_path, MAX_CONTROL_BYTES))
    if not isinstance(value, dict):
        raise TypeError(f"{index_path}: invalid qualification index")
    source = value.get("source")
    reports = value.get("reports")
    artifacts = value.get("artifacts")
    if (
        value.get("schema") != QUALIFICATION_SCHEMA
        or value.get("component") != args.component
        or value.get("scope") != "full"
        or value.get("target") != "x86_64-linux"
        or value.get("optimize") != "ReleaseFast"
        or not isinstance(source, dict)
        or not isinstance(reports, list)
        or not isinstance(artifacts, list)
    ):
        raise ValueError(f"{index_path}: not a full {args.component} qualification")
    current = source_information(root)
    if (
        source.get("tracked_dirty") is not False
        or current.get("tracked_dirty") is not False
    ):
        raise ValueError("baseline and comparison require clean qualified source")
    if source.get("revision") != current.get("revision"):
        raise ValueError("qualification source revision is stale")
    report_rows = {}
    for report in reports:
        if (
            not isinstance(report, dict)
            or not isinstance(report.get("file"), str)
            or type(report.get("rows")) is not int
            or report["rows"] <= 0
            or report["file"] != Path(report["file"]).name
            or report["file"] in report_rows
        ):
            raise ValueError(f"{index_path}: invalid qualification report record")
        report_rows[report["file"]] = report["rows"]
    eligible_paths = {path.resolve() for path in args.eligibility}
    qualified_paths = {
        (index_path.parent / name).resolve(): rows for name, rows in report_rows.items()
    }
    selected_reports = eligible_paths.intersection(qualified_paths)
    if not selected_reports:
        raise ValueError(
            "measurement does not use a report from the qualification index"
        )
    if any(
        index_path.stat().st_mtime_ns <= path.stat().st_mtime_ns
        for path in qualified_paths
    ):
        raise ValueError("qualification index is not newer than its eligibility report")
    for path, expected_rows in qualified_paths.items():
        _, rows = check_tsv(path)
        if len(rows) != expected_rows:
            raise ValueError(f"{path}: qualification row count differs from index")

    indexed_artifacts = {}
    for artifact in artifacts:
        if (
            not isinstance(artifact, dict)
            or not isinstance(artifact.get("path"), str)
            or type(artifact.get("size")) is not int
            or type(artifact.get("mtime_ns")) is not int
        ):
            raise ValueError(f"{index_path}: invalid qualification artifact record")
        artifact_path = Path(artifact["path"]).resolve()
        if artifact_path in indexed_artifacts:
            raise ValueError(f"{index_path}: duplicate qualification artifact")
        indexed_artifacts[artifact_path] = artifact
    if not indexed_artifacts:
        raise ValueError(f"{index_path}: empty qualification artifact set")
    matched_artifacts = 0
    selected_names = set(args.target)
    for target_path, bin_dir in zip(args.targets, args.bin_dir, strict=True):
        for target in target_rows(target_path):
            if target["name"] not in selected_names:
                continue
            executable = (bin_dir / target["executable"]).resolve()
            indexed = indexed_artifacts.get(executable)
            if indexed is None:
                continue
            if file_information(executable) != indexed:
                raise ValueError(f"qualified artifact changed: {executable}")
            matched_artifacts += 1
    if matched_artifacts == 0:
        raise ValueError("measurement does not use an artifact from qualification")


def measurement_common(command: list[str], args: argparse.Namespace) -> None:
    command.extend(("--manifest", str(args.manifest)))
    for path in args.eligibility:
        command.extend(("--eligibility", str(path)))
    for path in args.targets:
        command.extend(("--targets", str(path)))
    for path in args.bin_dir:
        command.extend(("--bin-dir", str(path)))
    for target in args.target:
        command.extend(("--target", target))
    for lane in args.lane:
        command.extend(("--lane", lane))
    for argument in args.program_arg:
        command.extend(("--program-arg", argument))
    command.extend(
        (
            "--workload",
            args.workload,
            "--duration-ms",
            str(args.duration_ms),
            "--samples",
            str(args.samples),
            "--warmups",
            str(args.warmups),
            "--timeout",
            str(args.timeout),
            "--max-output-bytes",
            str(args.max_output_bytes),
        )
    )
    if args.zebrac is not None:
        command.extend(("--zebrac", str(args.zebrac)))
    if args.dry_run:
        command.append("--dry-run")


def read_rows(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    lines = read_limited(path).decode("utf-8").splitlines()
    rows = csv.DictReader(
        (line for line in lines if not line.startswith("#")), delimiter="\t"
    )
    if rows.fieldnames is None:
        raise ValueError(f"{path}: missing TSV header")
    return list(rows.fieldnames), list(rows)


def merge_result_rows(destination: Path, source: Path, keys: tuple[str, ...]) -> None:
    fields, rows = read_rows(source)
    existing: list[dict[str, str]] = []
    if destination.is_file():
        old_fields, existing = read_rows(destination)
        if old_fields != fields:
            raise ValueError(f"{destination}: result columns differ")
    by_key = {tuple(row[key] for key in keys): row for row in existing}
    for row in rows:
        by_key[tuple(row[key] for key in keys)] = row
    publish_tsv(destination, fields, list(by_key.values()))


def metric(value: object, name: str) -> tuple[float, float, int]:
    if not isinstance(value, dict):
        raise TypeError(f"invalid Zebrac {name} metric")
    mean = value.get("mean")
    standard = value.get("std_dev")
    samples = value.get("sample_count")
    if (
        type(mean) not in {int, float}
        or type(standard) not in {int, float}
        or type(samples) is not int
        or not math.isfinite(mean)
        or not math.isfinite(standard)
        or mean < 0
        or standard < 0
        or samples <= 0
    ):
        raise ValueError(f"invalid Zebrac {name} values")
    return float(mean), float(standard), samples


def read_aa_results(raw: Path) -> list[dict[str, object]]:
    value = json.loads(read_limited(raw, MAX_CONTROL_BYTES))
    if not isinstance(value, dict) or not isinstance(value.get("results"), list):
        raise TypeError(f"{raw}: invalid Zebrac result")
    results = value["results"]
    if len(results) != 2:
        raise ValueError(f"{raw}: A/A result count differs")
    if any(not isinstance(result, dict) for result in results):
        raise TypeError(f"{raw}: invalid A/A result")
    return results


def publish_controls(
    root: Path,
    component: str,
    workload: str,
    target: str,
    raw: Path,
) -> None:
    results = read_aa_results(raw)
    measured = []
    for result in results:
        wall = metric(result.get("wall_time"), "wall_time")
        instructions = metric(result.get("instructions"), "instructions")
        if wall[2] != instructions[2] or wall[0] <= 0 or instructions[0] <= 0:
            raise ValueError(f"{raw}: invalid A/A samples")
        measured.append((wall, instructions))
    wall_drift = (
        abs(measured[0][0][0] - measured[1][0][0])
        / min(measured[0][0][0], measured[1][0][0])
        * 100
    )
    instruction_drift = (
        abs(measured[0][1][0] - measured[1][1][0])
        / min(measured[0][1][0], measured[1][1][0])
        * 100
    )
    rows = []
    for side, values in zip(("left", "right"), measured, strict=True):
        wall, instructions = values
        rows.append(
            {
                "component": component,
                "workload": workload,
                "target": target,
                "side": side,
                "samples": wall[2],
                "wall_mean_ns": f"{wall[0]:.6f}",
                "wall_cv_pct": f"{wall[1] / wall[0] * 100:.6f}",
                "instructions_mean": f"{instructions[0]:.6f}",
                "wall_drift_pct": f"{wall_drift:.6f}",
                "instructions_drift_pct": f"{instruction_drift:.6f}",
            }
        )
    destination = root / "controls.tsv"
    existing: list[dict[str, str]] = []
    if destination.is_file():
        lines = read_limited(destination).decode("utf-8").splitlines()
        reader = csv.DictReader(
            (line for line in lines if not line.startswith("#")), delimiter="\t"
        )
        if reader.fieldnames != CONTROL_FIELDS:
            raise ValueError(f"{destination}: control columns differ")
        existing = list(reader)
    keyed = {(row["workload"], row["target"], row["side"]): row for row in existing}
    for row in rows:
        keyed[(row["workload"], row["target"], row["side"])] = row
    temporary = destination.with_name(destination.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        stream.write(f"# {CONTROL_SCHEMA}\n")
        writer = csv.DictWriter(
            stream, CONTROL_FIELDS, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(keyed.values())
    temporary.replace(destination)


def target_contract(paths: list[Path], name: str) -> dict[str, str]:
    matches = [
        row for path in paths for row in target_rows(path) if row["name"] == name
    ]
    if len(matches) != 1:
        raise ValueError(f"expected one target declaration for {name}")
    return matches[0]


def eligibility_row(
    args: argparse.Namespace, contract: dict[str, str]
) -> dict[str, str]:
    fields, rows = read_rows(args.eligibility[0])
    required = {"target", "workload", "verdict"}
    if required.difference(fields):
        raise ValueError(f"{args.eligibility[0]}: incomplete eligibility columns")
    arguments = " ".join(args.program_arg) or "-"
    matches = [
        row
        for row in rows
        if row["target"] == args.target[0]
        and row["workload"] == args.workload
        and row["verdict"] == "pass"
        and ("work_lane" not in fields or row["work_lane"] == contract["work_lane"])
        and (
            "input_model" not in fields or row["input_model"] == contract["input_model"]
        )
        and ("program_args" not in fields or row["program_args"] == arguments)
    ]
    if len(matches) != 1:
        raise ValueError("eligibility does not contain one exact passing row")
    return matches[0]


def first_value(row: dict[str, str], names: tuple[str, ...]) -> str:
    for name in names:
        value = row.get(name)
        if value not in {None, "", "-"}:
            return value
    return "not measured"


def publish_baseline_metrics(
    result_root: Path,
    args: argparse.Namespace,
    lane: str,
    evidence: Path,
) -> None:
    raw = evidence / "aa" / "zebrac.json"
    results = read_aa_results(raw)
    names = (
        "wall_time",
        "peak_rss",
        "instructions",
        "cpu_cycles",
        "cache_misses",
        "branch_misses",
    )
    values = {
        name: [metric(result.get(name), name) for result in results] for name in names
    }
    samples = values["wall_time"][0][2]
    if any(
        current[2] != samples
        for measurements in values.values()
        for current in measurements
    ):
        raise ValueError("A/A metric sample counts differ")
    wall_means = [current[0] for current in values["wall_time"]]
    instruction_means = [current[0] for current in values["instructions"]]
    wall_mean = sum(wall_means) / 2
    wall_drift = abs(wall_means[0] - wall_means[1]) / min(wall_means) * 100
    instruction_drift = (
        abs(instruction_means[0] - instruction_means[1]) / min(instruction_means) * 100
    )
    work_bytes = args.work_bytes
    eligibility = eligibility_row(args, target_contract(args.targets, args.target[0]))
    if work_bytes is None and lane == "writer":
        value = eligibility.get("output_bytes")
        if value not in {None, "", "-"}:
            work_bytes = int(value)
    throughput = (
        f"{work_bytes / (1024 * 1024) / (wall_mean / 1_000_000_000):.6f}"
        if work_bytes is not None
        else "not measured"
    )
    failed_samples = sum(
        int(result.get("failed_sample_count", 0)) for result in results
    )
    row = {
        "component": args.component,
        "workload": args.workload,
        "target": args.target[0],
        "lane": lane,
        "input_model": target_contract(args.targets, args.target[0])["input_model"],
        "program_arguments": " ".join(args.program_arg) or "-",
        "cache_state": "warm-after-declared-warmups",
        "work_bytes": work_bytes if work_bytes is not None else "not measured",
        "wall_mean_ns": f"{wall_mean:.6f}",
        "wall_max_cv_pct": f"{max(value[1] / value[0] for value in values['wall_time']) * 100:.6f}",
        "wall_drift_pct": f"{wall_drift:.6f}",
        "throughput_mib_s": throughput,
        "peak_rss_mean_bytes": f"{sum(value[0] for value in values['peak_rss']) / 2:.6f}",
        "instructions_mean": f"{sum(instruction_means) / 2:.6f}",
        "instructions_drift_pct": f"{instruction_drift:.6f}",
        "cycles_mean": f"{sum(value[0] for value in values['cpu_cycles']) / 2:.6f}",
        "cache_misses_mean": f"{sum(value[0] for value in values['cache_misses']) / 2:.6f}",
        "branch_misses_mean": f"{sum(value[0] for value in values['branch_misses']) / 2:.6f}",
        "samples": samples * 2,
        "failed_samples": failed_samples,
        "allocator_operations": first_value(
            eligibility,
            (
                "allocator_operations",
                "first_allocator_operations",
                "construction_allocator_operations",
                "primary_parse_allocator_operations",
            ),
        ),
        "owned_peak_bytes": first_value(
            eligibility,
            (
                "owned_peak_bytes",
                "peak_live_bytes",
                "construction_peak_bytes",
                "primary_parse_peak_live_bytes",
                "reader_peak_live_bytes",
            ),
        ),
        "retained_bytes": first_value(
            eligibility,
            (
                "retained_bytes",
                "retained_capacity",
                "retained_capacity_bytes",
                "primary_retained_capacity_bytes",
                "reader_retained_bytes",
            ),
        ),
        "evidence": str((evidence / "aa" / "index.json").relative_to(result_root)),
    }
    destination = result_root / "metrics.tsv"
    existing: list[dict[str, str]] = []
    if destination.is_file():
        lines = read_limited(destination).decode("utf-8").splitlines()
        reader = csv.DictReader(
            (line for line in lines if not line.startswith("#")), delimiter="\t"
        )
        if reader.fieldnames != METRIC_FIELDS:
            raise ValueError(f"{destination}: metric columns differ")
        existing = list(reader)
    key = (row["workload"], row["target"], row["program_arguments"])
    keyed = {
        (old["workload"], old["target"], old["program_arguments"]): old
        for old in existing
    }
    keyed[key] = row
    temporary = destination.with_name(destination.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        stream.write(f"# {METRIC_SCHEMA}\n")
        writer = csv.DictWriter(
            stream, METRIC_FIELDS, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(keyed.values())
    temporary.replace(destination)


def measure(args: argparse.Namespace, comparison: bool) -> int:
    root = project_root()
    result_root = (
        args.result_root or default_result_root(root, args.component)
    ).resolve()
    if result_root.is_relative_to(root) and not result_root.is_relative_to(
        root / "data" / "results"
    ):
        raise ValueError(
            "component result root must be under data/results or outside the repository"
        )
    state = validate_measurement_args(args, comparison)
    if state == "not-entered":
        if not args.dry_run:
            clear_measurement_result(result_root, args.operation)
            write_status(
                result_root,
                args.component,
                args.operation,
                state,
                args.not_entered,
            )
        print(f"{args.component} {args.operation}: not entered ({args.not_entered})")
        return 0
    if state == "no-eligible-peer":
        if not args.dry_run:
            clear_measurement_result(result_root, args.operation)
            write_status(
                result_root,
                args.component,
                args.operation,
                state,
                args.no_eligible_peer,
            )
        print(f"{args.component} compare: no eligible peer ({args.no_eligible_peer})")
        return 0
    check_full_qualification(args, root)
    lane = state
    if args.lane and set(args.lane) != {lane}:
        raise ValueError(f"selected lane differs from target declarations: {lane}")
    args.lane = [lane]
    evidence = result_root / "evidence" / args.operation / safe_name(args.workload)
    if comparison:
        matrix = python_command(root, "run-zebrac-matrix.py")
        measurement_common(matrix, args)
        matrix.extend(
            ("--max-bytes", str(args.max_bytes), "--output-dir", evidence / "matrix")
        )
        run(matrix, args.timeout, False)
        summary = python_command(
            root,
            "summarize-zebrac.py",
            "--index",
            evidence / "matrix" / "index.json",
        )
        for baseline in args.baseline:
            summary.extend(("--baseline", baseline))
        summary.extend(("--output-dir", evidence / "summary"))
        run(summary, args.timeout, args.dry_run)
        if not args.dry_run:
            merge_result_rows(
                result_root / "peers.tsv",
                evidence / "summary" / "rows.tsv",
                (
                    "case",
                    "lane",
                    "workload",
                    "target",
                    "input_model",
                    "program_arguments",
                ),
            )
            (result_root / "compare-status.tsv").unlink(missing_ok=True)
        return 0

    eligibility_row(args, target_contract(args.targets, args.target[0]))
    for destination, fields in (
        (result_root / "controls.tsv", CONTROL_FIELDS),
        (result_root / "metrics.tsv", METRIC_FIELDS),
    ):
        if destination.is_file() and read_rows(destination)[0] != fields:
            raise ValueError(f"{destination}: result columns differ")
    aa = python_command(root, "run-zebrac-aa.py")
    aa_args = argparse.Namespace(**vars(args))
    aa_args.targets = [args.targets[0]]
    aa_args.bin_dir = [args.bin_dir[0]]
    aa_args.eligibility = [args.eligibility[0]]
    aa_args.target = [args.target[0]]
    aa_args.lane = []
    measurement_common(aa, aa_args)
    aa.extend(("--output-dir", evidence / "aa"))
    run(aa, args.timeout, False)
    if not args.dry_run:
        publish_baseline_metrics(result_root, args, lane, evidence)
        publish_controls(
            result_root,
            args.component,
            args.workload,
            args.target[0],
            evidence / "aa" / "zebrac.json",
        )
        (result_root / "baseline-status.tsv").unlink(missing_ok=True)
    return 0


def main() -> int:
    args = parse_args()
    try:
        if args.operation == "qualify":
            return qualify(args)
        return measure(args, args.operation == "compare")
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
