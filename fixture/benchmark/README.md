# Benchmark Fixtures

Status: **Active** (last updated: 2026-08-22)

Benchmark data is downstream of correctness. The `smoke/` documents are tiny command and output checks, not performance baselines. Medium and large files will be generated or downloaded from pinned manifests and remain outside Git.

The durable shape contract is [`plans/shape-matrix-v1.tsv`](plans/shape-matrix-v1.tsv). Its checked-in seeds live in the ordinary `valid/` and `invalid/` fixture trees so the profile-aware correctness gate can qualify them. Namespace, UTF-16, DTD, validation, DOM, rejection, resource-limit, and real-data lanes with `planned` status are not benchmark eligible until their parser profile and oracle exist.

[`plans/oracles-v1.tsv`](plans/oracles-v1.tsv) defines the semantic result required by each lane. A compact event checksum is sufficient for the qualified UTF-8/no-DTD overlap; namespace, encoding, validation, DOM, diagnostic, limit, and real-data rows have explicit result fields before they become eligible.

A workload becomes benchmark-eligible only when its manifest entry names a parser profile and the correctness runner passes every target included in that timing comparison. Invalid-input timing is a separate rejection workload and records whether the first fatal byte is early, middle, or late.

`tools/generate-benchmark-corpus.py` creates the versioned performance corpus outside this checked-in tree. Its manifest records exact sizes, feature requirements, expected semantic summaries, and rejection positions. After `make -C ref all`, use `make -C ref generate-corpus` followed by `make -C ref check-generated` before selecting commands for zebrac.

The UTF-8/no-DTD generator includes long text, dense markup, fixed and varied attribute workloads, varied shallow records, mixed content, references, Unicode, deep nesting, and early/middle/late structural rejection. The varied-record workloads are intended to prevent a benchmark from rewarding one repeated byte pattern.

[`plans/full-1g.tsv`](plans/full-1g.tsv) is the audited large recipe. It spans 1, 16, 64, 256, and 1024 MiB without allowing any file above exactly 1 GiB. After `make -C ref all`, run `make -C ref generate-corpus-full verify-corpus-full` to materialize and directly verify it outside `fixture/`.

Persistent-process measurements use generated 1, 16, 64, and 256 KiB versions of every common shape. The namespace lane has its own namespace-churn manifest because its summary includes expanded-name counters. Build the maintained adapters, materialize both corpora, and run the exact qualification gate with:

```sh
zig build persistent-adapters -Doptimize=ReleaseFast
make -C ref all
make -C ref generate-corpus-persistent generate-namespace-corpus
make -C ref check-generated-persistent
```

These inputs isolate parser setup, reset, callback, and tiny-document latency without process startup dominating each parse. `verify-corpus-persistent` and `verify-namespace-corpus` check existing generated files without rewriting them.

Check the tracked shape references before generating data:

```sh
make -C ref check-shape-matrix
```
