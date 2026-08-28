#!/usr/bin/env python3
"""Calculate comparable metrics from qualified Zebrac matrix results."""

from __future__ import annotations

import argparse
import csv
import json
import math
import shlex
import sys
from datetime import datetime, timezone
from pathlib import Path

MATRIX_SCHEMAS = {"z-xml-zebrac-matrix-v2", "z-xml-zebrac-matrix-v3"}
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
ROW_FIELDS = [
    "case",
    "lane",
    "workload",
    "classification",
    "target",
    "processor_class",
    "input_model",
    "program_arguments",
    "input_bytes",
    "work_multiplier",
    "work_bytes",
    "samples",
    "failed_samples",
    "wall_mean_ns",
    "wall_std_dev_ns",
    "wall_cv_pct",
    "wall_min_ns",
    "wall_max_ns",
    "throughput_mib_s",
    "peak_rss_mean_mib",
    "peak_rss_max_mib",
    "minor_faults_mean",
    "major_faults_mean",
    "cycles_mean",
    "instructions_mean",
    "instructions_per_byte",
    "cycles_per_byte",
    "ipc",
    "cache_references_mean",
    "cache_misses_mean",
    "cache_miss_pct",
    "cache_misses_per_mib",
    "branch_misses_mean",
    "branch_misses_per_mib",
    "wall_vs_baseline",
    "throughput_vs_baseline",
    "rss_vs_baseline",
    "cycles_vs_baseline",
    "instructions_vs_baseline",
    "cache_misses_vs_baseline",
    "branch_misses_vs_baseline",
]
AGGREGATE_FIELDS = [
    "case",
    "lane",
    "classification",
    "target",
    "baseline",
    "target_workloads",
    "baseline_workloads",
    "compared_workloads",
    "complete_coverage",
    "wall_geomean_vs_baseline",
    "throughput_geomean_vs_baseline",
    "rss_geomean_vs_baseline",
    "cycles_geomean_vs_baseline",
    "instructions_geomean_vs_baseline",
    "cache_misses_geomean_vs_baseline",
    "branch_misses_geomean_vs_baseline",
    "max_peak_rss_mean_mib",
    "max_wall_cv_pct",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, action="append", required=True)
    parser.add_argument(
        "--baseline",
        action="append",
        required=True,
        help="LANE=TARGET; repeat for each measured lane",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def read_json(path: Path) -> object:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def read_baselines(values: list[str]) -> dict[str, str]:
    baselines: dict[str, str] = {}
    for value in values:
        lane, separator, target = value.partition("=")
        if not separator or not lane or not target:
            raise ValueError(f"invalid baseline {value!r}; expected LANE=TARGET")
        if lane in baselines:
            raise ValueError(f"duplicate baseline for lane {lane}")
        baselines[lane] = target
    return baselines


def metric(
    result: dict[str, object], name: str, expected_samples: int
) -> dict[str, float]:
    value = result.get(name)
    if not isinstance(value, dict) or value.get("unit") != METRIC_UNITS[name]:
        raise ValueError(f"invalid {name} metric")
    required = ("mean", "std_dev", "min", "max")
    if any(type(value.get(field)) not in (int, float) for field in required):
        raise ValueError(f"incomplete {name} metric")
    if value.get("sample_count") != expected_samples:
        raise ValueError(f"{name} sample count differs")
    return {field: float(value[field]) for field in required}


def ratio(left: float, right: float) -> float | None:
    return left / right if right > 0 else None


def per_work(value: float, classification: str, work_bytes: int) -> float | None:
    if classification != "benchmark-valid" or work_bytes <= 0:
        return None
    return value / work_bytes


def collect_rows(index_paths: list[Path]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    identities: set[tuple[str, str, str, str]] = set()
    for index_path in index_paths:
        index = read_json(index_path)
        if not isinstance(index, dict) or index.get("schema") not in MATRIX_SCHEMAS:
            raise ValueError(f"{index_path}: unsupported matrix schema")
        case = str(index.get("measurement_case", "end-to-end"))
        multiplier = int(index.get("work_multiplier", 1))
        target_metadata = index.get("target_binaries")
        program_arguments = index.get("program_arguments", [])
        runs = index.get("runs")
        if (
            multiplier <= 0
            or not isinstance(target_metadata, dict)
            or not isinstance(program_arguments, list)
            or not isinstance(runs, list)
        ):
            raise ValueError(f"{index_path}: incomplete matrix index")
        for run in runs:
            if not isinstance(run, dict) or run.get("status") != 0:
                raise ValueError(f"{index_path}: contains an unsuccessful matrix run")
            raw_path = index_path.parent / str(run["zebrac_json"])
            raw = read_json(raw_path)
            if not isinstance(raw, dict) or raw.get("schema_version") != 1:
                raise ValueError(f"{raw_path}: unsupported Zebrac schema")
            results = raw.get("results")
            targets = run.get("targets")
            input_models = run.get("input_models")
            commands = run.get("commands")
            if not all(
                isinstance(value, list)
                for value in (results, targets, input_models, commands)
            ):
                raise ValueError(f"{index_path}: incomplete run lists")
            assert isinstance(results, list)
            assert isinstance(targets, list)
            assert isinstance(input_models, list)
            assert isinstance(commands, list)
            if not (len(results) == len(targets) == len(input_models) == len(commands)):
                raise ValueError(f"{index_path}: run list lengths differ")
            classification = str(run["classification"])
            input_bytes = int(run["bytes"])
            work_bytes = int(run.get("work_bytes", input_bytes * multiplier))
            if (
                classification not in {"benchmark-valid", "not-well-formed"}
                or input_bytes <= 0
                or work_bytes != input_bytes * multiplier
            ):
                raise ValueError(f"{index_path}: invalid run work metadata")
            for target, input_model, command, result in zip(
                targets, input_models, commands, results, strict=True
            ):
                if not isinstance(result, dict) or result.get("command") != command:
                    raise ValueError(f"{raw_path}: command order differs")
                samples = result.get("sample_count")
                failed_samples = result.get("failed_sample_count")
                if (
                    type(samples) is not int
                    or samples <= 0
                    or type(failed_samples) is not int
                    or failed_samples < 0
                    or failed_samples > samples
                    or (classification == "benchmark-valid" and failed_samples != 0)
                    or (
                        classification == "not-well-formed"
                        and failed_samples != samples
                    )
                ):
                    raise ValueError(f"{raw_path}: invalid sample outcome")
                metadata = target_metadata.get(str(target))
                if not isinstance(metadata, dict):
                    raise TypeError(f"{index_path}: missing metadata for {target}")
                identity = (case, str(run["lane"]), str(run["workload"]), str(target))
                if identity in identities:
                    raise ValueError(f"duplicate result for {'/'.join(identity)}")
                identities.add(identity)
                wall = metric(result, "wall_time", samples)
                rss = metric(result, "peak_rss", samples)
                minor = metric(result, "minor_faults", samples)
                major = metric(result, "major_faults", samples)
                cycles = metric(result, "cpu_cycles", samples)
                instructions = metric(result, "instructions", samples)
                cache_references = metric(result, "cache_references", samples)
                cache_misses = metric(result, "cache_misses", samples)
                branch_misses = metric(result, "branch_misses", samples)
                mib = work_bytes / (1024 * 1024)
                throughput = (
                    work_bytes * 1_000_000_000 / wall["mean"] / (1024 * 1024)
                    if classification == "benchmark-valid" and wall["mean"] > 0
                    else None
                )
                rows.append(
                    {
                        "case": case,
                        "lane": str(run["lane"]),
                        "workload": str(run["workload"]),
                        "classification": classification,
                        "target": str(target),
                        "processor_class": str(
                            metadata.get("processor_class", "unknown")
                        ),
                        "input_model": str(input_model),
                        "program_arguments": shlex.join(
                            [str(argument) for argument in program_arguments]
                        ),
                        "input_bytes": input_bytes,
                        "work_multiplier": multiplier,
                        "work_bytes": work_bytes,
                        "samples": samples,
                        "failed_samples": failed_samples,
                        "wall_mean_ns": wall["mean"],
                        "wall_std_dev_ns": wall["std_dev"],
                        "wall_cv_pct": ratio(wall["std_dev"] * 100, wall["mean"]),
                        "wall_min_ns": wall["min"],
                        "wall_max_ns": wall["max"],
                        "throughput_mib_s": throughput,
                        "peak_rss_mean_mib": rss["mean"] / (1024 * 1024),
                        "peak_rss_max_mib": rss["max"] / (1024 * 1024),
                        "minor_faults_mean": minor["mean"],
                        "major_faults_mean": major["mean"],
                        "cycles_mean": cycles["mean"],
                        "instructions_mean": instructions["mean"],
                        "instructions_per_byte": per_work(
                            instructions["mean"], classification, work_bytes
                        ),
                        "cycles_per_byte": per_work(
                            cycles["mean"], classification, work_bytes
                        ),
                        "ipc": ratio(instructions["mean"], cycles["mean"]),
                        "cache_references_mean": cache_references["mean"],
                        "cache_misses_mean": cache_misses["mean"],
                        "cache_miss_pct": ratio(
                            cache_misses["mean"] * 100, cache_references["mean"]
                        ),
                        "cache_misses_per_mib": (
                            cache_misses["mean"] / mib
                            if classification == "benchmark-valid" and mib > 0
                            else None
                        ),
                        "branch_misses_mean": branch_misses["mean"],
                        "branch_misses_per_mib": (
                            branch_misses["mean"] / mib
                            if classification == "benchmark-valid" and mib > 0
                            else None
                        ),
                    }
                )
    return rows


def add_baseline_ratios(
    rows: list[dict[str, object]], baselines: dict[str, str]
) -> None:
    observed_lanes = {str(row["lane"]) for row in rows}
    missing = observed_lanes.difference(baselines)
    if missing:
        raise ValueError("missing baselines for lanes: " + ",".join(sorted(missing)))
    by_identity = {
        (
            str(row["case"]),
            str(row["lane"]),
            str(row["workload"]),
            str(row["target"]),
        ): row
        for row in rows
    }
    for row in rows:
        baseline = by_identity.get(
            (
                str(row["case"]),
                str(row["lane"]),
                str(row["workload"]),
                baselines[str(row["lane"])],
            )
        )
        row["wall_vs_baseline"] = None
        row["throughput_vs_baseline"] = None
        row["rss_vs_baseline"] = None
        row["cycles_vs_baseline"] = None
        row["instructions_vs_baseline"] = None
        row["cache_misses_vs_baseline"] = None
        row["branch_misses_vs_baseline"] = None
        if baseline is None:
            continue
        row["wall_vs_baseline"] = ratio(
            float(row["wall_mean_ns"]), float(baseline["wall_mean_ns"])
        )
        if (
            row["throughput_mib_s"] is not None
            and baseline["throughput_mib_s"] is not None
        ):
            row["throughput_vs_baseline"] = ratio(
                float(row["throughput_mib_s"]),
                float(baseline["throughput_mib_s"]),
            )
        row["rss_vs_baseline"] = ratio(
            float(row["peak_rss_mean_mib"]),
            float(baseline["peak_rss_mean_mib"]),
        )
        row["cycles_vs_baseline"] = ratio(
            float(row["cycles_mean"]),
            float(baseline["cycles_mean"]),
        )
        row["instructions_vs_baseline"] = ratio(
            float(row["instructions_mean"]),
            float(baseline["instructions_mean"]),
        )
        row["cache_misses_vs_baseline"] = ratio(
            float(row["cache_misses_mean"]),
            float(baseline["cache_misses_mean"]),
        )
        row["branch_misses_vs_baseline"] = ratio(
            float(row["branch_misses_mean"]),
            float(baseline["branch_misses_mean"]),
        )


def geomean(values: list[float]) -> float | None:
    if not values or any(value <= 0 for value in values):
        return None
    return math.exp(sum(math.log(value) for value in values) / len(values))


def field_values(
    rows: dict[str, dict[str, object]], workloads: list[str], field: str
) -> list[float]:
    values = []
    for workload in workloads:
        value = rows[workload].get(field)
        if value is not None:
            values.append(float(value))
    return values


def aggregate(
    rows: list[dict[str, object]], baselines: dict[str, str]
) -> list[dict[str, object]]:
    groups: dict[tuple[str, str, str, str], list[dict[str, object]]] = {}
    for row in rows:
        key = (
            str(row["case"]),
            str(row["lane"]),
            str(row["classification"]),
            str(row["target"]),
        )
        groups.setdefault(key, []).append(row)
    aggregates: list[dict[str, object]] = []
    for key, target_rows in sorted(groups.items()):
        case, lane, classification, target = key
        baseline_target = baselines[lane]
        baseline_rows = groups.get((case, lane, classification, baseline_target), [])
        target_by_workload = {str(row["workload"]): row for row in target_rows}
        baseline_by_workload = {str(row["workload"]): row for row in baseline_rows}
        shared = sorted(target_by_workload.keys() & baseline_by_workload.keys())

        aggregates.append(
            {
                "case": case,
                "lane": lane,
                "classification": classification,
                "target": target,
                "baseline": baseline_target,
                "target_workloads": len(target_by_workload),
                "baseline_workloads": len(baseline_by_workload),
                "compared_workloads": len(shared),
                "complete_coverage": set(target_by_workload)
                == set(baseline_by_workload),
                "wall_geomean_vs_baseline": geomean(
                    field_values(target_by_workload, shared, "wall_vs_baseline")
                ),
                "throughput_geomean_vs_baseline": geomean(
                    field_values(target_by_workload, shared, "throughput_vs_baseline")
                ),
                "rss_geomean_vs_baseline": geomean(
                    field_values(target_by_workload, shared, "rss_vs_baseline")
                ),
                "cycles_geomean_vs_baseline": geomean(
                    field_values(target_by_workload, shared, "cycles_vs_baseline")
                ),
                "instructions_geomean_vs_baseline": geomean(
                    field_values(target_by_workload, shared, "instructions_vs_baseline")
                ),
                "cache_misses_geomean_vs_baseline": geomean(
                    field_values(target_by_workload, shared, "cache_misses_vs_baseline")
                ),
                "branch_misses_geomean_vs_baseline": geomean(
                    field_values(
                        target_by_workload, shared, "branch_misses_vs_baseline"
                    )
                ),
                "max_peak_rss_mean_mib": max(
                    float(row["peak_rss_mean_mib"]) for row in target_rows
                ),
                "max_wall_cv_pct": max(
                    float(row["wall_cv_pct"] or 0) for row in target_rows
                ),
            }
        )
    return aggregates


def serialized(value: object) -> object:
    if value is None:
        return ""
    if isinstance(value, float):
        return f"{value:.9g}"
    if isinstance(value, bool):
        return "yes" if value else "no"
    return value


def write_tsv(path: Path, fields: list[str], rows: list[dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: serialized(row.get(field)) for field in fields})


def write_text_report(path: Path, aggregates: list[dict[str, object]]) -> None:
    lines = [
        "Ratios are target divided by the named baseline.",
        "Wall and RSS ratios below 1 use less. Throughput ratios above 1 process more.",
        "No ratio combines different lanes or measurement cases.",
        "",
    ]
    current: tuple[str, str, str] | None = None
    for row in aggregates:
        group = (str(row["case"]), str(row["lane"]), str(row["classification"]))
        if group != current:
            if current is not None:
                lines.append("")
            lines.append(f"{group[0]} | {group[1]} | {group[2]}")
            current = group
        wall = serialized(row["wall_geomean_vs_baseline"])
        throughput = serialized(row["throughput_geomean_vs_baseline"])
        rss = serialized(row["rss_geomean_vs_baseline"])
        cycles = serialized(row["cycles_geomean_vs_baseline"])
        instructions = serialized(row["instructions_geomean_vs_baseline"])
        cache_misses = serialized(row["cache_misses_geomean_vs_baseline"])
        branch_misses = serialized(row["branch_misses_geomean_vs_baseline"])
        lines.append(
            f"  {row['target']}: wall {wall or 'n/a'}, throughput {throughput or 'n/a'}, "
            f"RSS {rss or 'n/a'}, instructions {instructions or 'n/a'}, "
            f"coverage {row['compared_workloads']}/{row['baseline_workloads']}, "
            f"max RSS {float(row['max_peak_rss_mean_mib']):.3f} MiB, "
            f"max wall CV {float(row['max_wall_cv_pct']):.3f}%"
        )
        lines.append(
            f"    counters: cycles {cycles or 'n/a'}, cache misses "
            f"{cache_misses or 'n/a'}, branch misses {branch_misses or 'n/a'}"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    try:
        baselines = read_baselines(args.baseline)
        rows = collect_rows([path.resolve() for path in args.index])
        add_baseline_ratios(rows, baselines)
        aggregates = aggregate(rows, baselines)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    args.output_dir.mkdir(parents=True, exist_ok=True)
    rows.sort(
        key=lambda row: (
            str(row["case"]),
            str(row["lane"]),
            str(row["classification"]),
            str(row["workload"]),
            str(row["target"]),
        )
    )
    write_tsv(args.output_dir / "rows.tsv", ROW_FIELDS, rows)
    write_tsv(args.output_dir / "aggregates.tsv", AGGREGATE_FIELDS, aggregates)
    report = {
        "schema": "z-xml-zebrac-summary-v1",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "indexes": [str(path.resolve()) for path in args.index],
        "baselines": baselines,
        "rows": rows,
        "aggregates": aggregates,
    }
    (args.output_dir / "report.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    write_text_report(args.output_dir / "report.txt", aggregates)
    print(f"summarized {len(rows)} target results into {len(aggregates)} groups")
    print(f"results: {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
