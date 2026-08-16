# Benchmark Fixtures

Status: **Active** (last updated: 2026-08-15)

Benchmark data is downstream of correctness. The `smoke/` documents are tiny command and output checks, not performance baselines. Medium and large files will be generated or downloaded from pinned manifests and remain outside Git.

A workload becomes benchmark-eligible only when its manifest entry names a parser profile and the correctness runner passes every target included in that timing comparison. Invalid-input timing is a separate rejection workload and records whether the first fatal byte is early, middle, or late.

`tools/generate-benchmark-corpus.py` creates the versioned performance corpus outside this checked-in tree. Its manifest records exact sizes, feature requirements, expected semantic summaries, and rejection positions. Use `make -C ref generate-corpus` followed by `make -C ref check-generated` before selecting commands for zebrac.

[`plans/full-1g.tsv`](plans/full-1g.tsv) is the audited large recipe. It spans 1, 16, 64, 256, and 1024 MiB without allowing any file above exactly 1 GiB. Run `make -C ref TUNE=native generate-corpus-full verify-corpus-full` to materialize and directly verify it outside `fixture/`.

Persistent-process measurements use generated 1, 16, 64, and 256 KiB versions of every common shape. Run `make -C ref generate-corpus-persistent` to materialize them under `data/generated/z-xml-generated-v3-persistent/`. These inputs isolate parser setup, reset, callback, and tiny-document latency without process startup dominating each parse.
