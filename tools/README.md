# Tools

Status: **Active** (last updated: 2026-08-29)

`tools/` contains development commands and XML adapters. It is excluded from the Zig package.

Files are grouped by language. The Python commands are called through their configured interpreter, so they need no wrappers or package files.

- `build.zig` builds the Zig adapters and layout probe.
- `zig/` contains adapter source code compiled by `build.zig`.
- `python/` contains checks, generators, and measurement commands called through Python.
- `targets.tsv` describes the z-xml adapter capabilities used by fixture checks.
- `writer-targets.tsv` declares the one manifest-driven Writer adapter.
- `fetch-w3c-xmlconf.sh` downloads the pinned W3C suite. It stays at the root because it is the only shell command.

Use `make -C ref` for commands that work with fixtures, generated XML, or reference parsers. Use `zig build --build-file tools/build.zig` to build the z-xml adapters.

## Ownership map

The paths below are the complete tracked tool set. Python commands use their configured interpreter, the shell command runs directly, and `tools/build.zig` compiles only the Zig sources.

Build and declarations:

- `README.md` owns this command and file map. `plan/AGENTS.md` and `plan/ROADMAP.md` point developers here instead of duplicating tool details.
- `build.zig` owns the Zig tool build. Its callers are the documented `zig build --build-file tools/build.zig` commands. It imports the package module and the Zig tool sources, then installs adapters under `tools/zig-out/bin` or runs the layout probe and tool tests.
- `targets.tsv` declares the six z-xml Reader profiles used by `ref/check-corpus.sh`, `run-w3c-xmlconf.py`, `run-valgrind.py`, and `run-zebrac-matrix.py`. It has no output of its own.
- `persistent-targets.tsv` declares the protocol, consumer, memory-report, namespace, lane, and input-model support of the three z-xml repeated-input adapters. It has no output of its own.
- `writer-targets.tsv` declares the protocol, oracle, sink, and memory-report support of `z-xml-writer`. `check-shape-matrix.py` checks its schema and exact target row.

Zig sources:

- `zig/check.zig` owns the single-file event-summary protocol. The `corpus-adapters` step builds its six raw-name or namespace-aware DTD modes. Corpus and conformance commands pass an XML path; DTD modes resolve companion sources from that path. Each executable writes one JSON summary to standard output.
- `zig/persistent.zig` owns repeated Reader work over resident or streamed input. The `persistent-adapters` step builds raw-name, namespace-aware, and default-Reader executables. `check-generated-persistent.py`, `check-reader-scale`, and measurement commands pass the input model, consumer, iteration count, chunk size, and XML path; the executable writes one JSON result.
- `zig/tree.zig` owns public `Document` construction and traversal measurement. The `tree-adapter` step builds `z-xml-tree`. Normal output reports node counts, depth, and common and complete-traversal checksums. `--timing` separates construction and traversal time. `--memory` separates retained Document capacity, construction allocation work, and traversal scratch allocation work. Each mode writes one JSON result.
- `zig/writer.zig` owns manifest-selected public Writer work. The `writer-adapter` step builds `z-xml-writer`. It runs the attributes, unchanged-text, escaped-text, fragmented-text, namespace-depth, short-sink, and repeated-document shapes declared in `bench/shapes.tsv`. Each run writes one JSON result. `--verify` retains output for exact or Reader checks before measurement.
- `zig/validation_repeat.zig` owns fresh-versus-reused external DTD validation. The `validation-bench` step builds both modes. Each executable accepts a DTD path, XML path, and repetition count and writes one JSON result.
- `zig/layout_probe.zig` owns development-only Reader and Document type-size output. The `layout` step runs it and prints tab-separated rows to standard error; it does not install an adapter.
- `zig/tracking_allocator.zig` is shared implementation for `persistent.zig`, `tree.zig`, and `writer.zig`. It has no command or build step of its own.

Generated inputs and declarations:

- `python/generate-byte-fixtures.py` owns the byte-sensitive files under `fixture/valid/encoding/` and `fixture/invalid/encoding/`. `make -C ref check-byte-fixtures`, `make -C ref check-corpus`, and `make -C ref check-reader-conformance` compare them without rewriting; direct generation rewrites only those files.
- `python/generate-unicode-normalization.py` owns `src/unicode_normalization.zig`. The Make targets call it through `UNICODE_PYTHON`. `make -C ref check-unicode-table` compares the table without rewriting; `make -C ref generate-unicode-table` rewrites it.
- `python/check-shape-matrix.py` checks ignored `bench/shapes.tsv`, `bench/oracles.tsv`, and `bench/full.tsv` against each other, `fixture/manifest.tsv`, and `writer-targets.tsv`. It rejects missing owners, incompatible lanes or input models, duplicate rows, invalid size plans, missing or changed Writer shapes, and Writer target drift. `make -C ref check-shape-matrix` prints a result and writes no file.
- `python/generate-benchmark-corpus.py` owns general generated XML and its manifest under the selected ignored output directory. Generation writes the requested shapes, sizes, and rejection positions. Check mode requires the same workload-selection arguments and compares the exact row order, fields, file set, and generated bytes without rewriting. The `generate-corpus`, `generate-corpus-full`, and `generate-corpus-persistent` Make targets call generation; the matching `verify-*` targets preserve that workload selection.
- `python/generate-namespace-benchmark.py` owns the namespace-churn XML and manifest under the selected ignored output directory. Check mode regenerates the requested corpus in a temporary directory and compares every file without rewriting the selected output. `make -C ref generate-namespace-corpus` generates it and `make -C ref verify-namespace-corpus` checks it.

Correctness and conformance:

- `python/check-persistent-adapters.py` owns the small repeated-input protocol smoke check. It accepts z-xml artifacts, peer artifacts, or both; checks one resident schedule and three distinct stream schedules for both consumers; enforces input, output, and time limits; and writes no file. `make -C ref check-persistent` calls the peer selection through `ref/build.sh`.
- `python/check-generated-corpus.py` owns single-document event qualification. It requires an exact generated-corpus schema and declared event targets, checks every manifest file before applying the byte selection, bounds each adapter process, and publishes its result TSV only when every executed row passes.
- `python/check-generated-persistent.py` owns repeated-input and scale qualification for one declared persistent target. It checks the target lane, input model, consumer features, corpus identity, source schedules, semantic output, minimal and full consumer parity, process limits, and optional memory report. It publishes its result TSV only when the complete run passes.
- `fetch-w3c-xmlconf.sh` owns the pinned W3C suite download and extraction under ignored `data/conformance/`. It checks the cached or downloaded archive, rejects unsafe archive paths, extracts through a temporary directory, and compares an existing destination with the pinned archive before reuse. `make -C ref fetch-xmlconf` calls it.
- `python/run-w3c-xmlconf.py` owns W3C catalog selection and parser-result classification. It follows the 21 manifests declared by the pinned root catalog and writes schema `z-xml-w3c-results-v1`. An absent W3C `VERSION` or `EDITION` is recorded as `all`. Every selected target and case has one `pass`, `fail`, `skip`, `mismatch`, `timeout`, or `tool-error` row. A skip keeps the W3C applicability class and gives a reason. External paths above the adapter's configured root require `external_parent_paths`. A complete report replaces the prior result atomically. Structural failures remove stale results. The command returns zero only when it records no failure, mismatch, timeout, or tool error. `make -C ref check-xmlconf` writes peer results; `make -C ref check-reader-conformance` writes separate z-xml results.

Resource and measurement commands:

- `python/run-valgrind.py` owns bounded Memcheck execution. Standalone mode checks one executable with an expected zero status. Corpus mode requires every selected target and case to have an exact passing correctness row. Both modes write logs and `metadata.json`; corpus mode also writes `results.tsv`. Metadata records the executable path and size, case, expected and observed status, semantic result, Valgrind result and error count, and descriptor counts. It does not report parser-owned memory or timing RSS.
- `python/run-zebrac-aa.py` owns A/A host-noise measurement for one exact qualified command. It derives the executable and input from their manifests, requires one fresh matching correctness row, and writes raw output, logs, and schema `z-xml-zebrac-aa-v3` under `--output-dir`.
- `python/run-zebrac-matrix.py` owns correctness-qualified matched measurement. Repeated `--targets` and `--bin-dir` pairs place z-xml and peer commands in the same workload and lane group. It requires fresh event or exact persistent qualification, bounds Zebrac time and output, and writes schema `z-xml-zebrac-matrix-v4` only after every selected run passes.
- `python/summarize-zebrac.py` owns result calculation. It reads one or more matrix-v4 indexes plus one baseline per lane, then writes row, aggregate, JSON, and text reports under `--output-dir`. It rejects failed rows, unmatched work, lane drift, missing metrics, and wrong units. It does not combine different lanes or measurement cases, and it does not calculate aggregate ratios from incomplete workload coverage.

Generation, correctness, conformance, resource checking, and timing remain separate because they produce different evidence. `bench/` and `data/` are ignored. `bench/` contains local plans and small benchmark inputs. `data/` contains generated XML, downloaded test suites, and results. Benchmark results remain local until the reproduction and comparison commands are qualified.

## Generated correctness

Build the required z-xml adapters, verify the existing generated inputs without rewriting them, and run both correctness paths with:

```sh
make -C ref check-generated
make -C ref check-generated-persistent
make -C ref check-peer-events
make -C ref check-peer-persistent
```

The first two commands check the declared z-xml event and persistent modes. The last two rebuild and check the peer event and persistent modes. Each command publishes results only after every executed row passes its exact oracle; unsupported feature rows remain recorded exclusions.

These safe commands must return nonzero because the selected target declares the wrong lane. Neither command publishes the requested result file:

```sh
python3 tools/python/check-generated-corpus.py \
    --manifest data/generated/z-xml-generated-v3/manifest.tsv \
    --targets tools/targets.tsv \
    --bin-dir tools/zig-out/bin \
    --target z-xml-raw-validate \
    --results /tmp/z-xml-wrong-event-lane.tsv

python3 tools/python/check-generated-persistent.py \
    --manifest data/generated/z-xml-generated-v3-persistent/manifest.tsv \
    --targets tools/persistent-targets.tsv \
    --target z-xml-ns-persistent \
    --program tools/zig-out/bin/z-xml-ns-persistent \
    --engine z-xml-ns \
    --results /tmp/z-xml-wrong-persistent-lane.tsv
```

## Build commands

Every Zig adapter imports `z_xml`, the public package root, through `tools/build.zig`.

The persistent adapter gives resident input to `Reader` as one slice. `--chunk-bytes` sizes the buffered file reader only for stream input. The resident result keeps the requested value in its protocol metadata, so resident rows with different chunk values are not different source schedules.

Build only the adapters you need:

```sh
zig build --build-file tools/build.zig corpus-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig tree-adapter -Doptimize=ReleaseFast
zig build --build-file tools/build.zig writer-adapter -Doptimize=ReleaseFast
zig build --build-file tools/build.zig validation-bench -Doptimize=ReleaseFast
zig build --build-file tools/build.zig reader-audit -Doptimize=Debug
zig build --build-file tools/build.zig layout -Doptimize=ReleaseFast
```

Check the benchmark plans and the z-xml repeated-input protocol with:

```sh
make -C ref check-shape-matrix
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
python3 tools/python/check-persistent-adapters.py --z-xml-bin-dir tools/zig-out/bin
```

The `tools` build step installs every adapter. The `test` step runs tests for the tool code. The separate `reader-audit` step installs the Reader test executable used for Memcheck; it is not part of the adapter union.

Run that executable under Memcheck with:

```sh
python3 tools/python/run-valgrind.py \
    --output-dir data/results/reader-audit \
    --standalone tools/zig-out/bin/z-xml-reader-audit
```

Run one correctness-qualified external-DTD case with:

```sh
python3 tools/python/run-valgrind.py \
    --manifest fixture/manifest.tsv \
    --eligibility ref/build/z-xml-focused-results.tsv \
    --targets tools/targets.tsv \
    --bin-dir tools/zig-out/bin \
    --output-dir data/results/valgrind-external-dtd \
    --workload dtd-external-entities \
    --target z-xml-raw-process
```

After validating the arguments and input or output path separation, the command removes stale `metadata.json` and `results.tsv` before reading control files or starting Valgrind. It publishes complete reports by replacement, kills the process group on timeout or Ctrl-C, and bounds each Valgrind log. An argument or path error leaves an earlier report untouched. A completed run publishes its pass or failure rows. A later structural failure may leave a diagnostic log but no metadata or result file.

These two small commands check the protocol without a package build. The first must return zero. The second must return nonzero because the executable status is wrong:

```sh
python3 tools/python/run-valgrind.py \
    --output-dir /tmp/z-xml-valgrind-pass \
    --standalone /usr/bin/true

python3 tools/python/run-valgrind.py \
    --output-dir /tmp/z-xml-valgrind-fail \
    --standalone /usr/bin/false
```

The Reader audit runs all 67 tests under Memcheck with the same stack-based Reader storage used by normal tests and fuzz campaigns.

The development build installs adapters under `tools/zig-out/bin` by default.

## Writer measurement

The Writer adapter accepts `MANIFEST SHAPE VALUE SINK`. The selected row must be a ready Writer row, the value must occur in its size plan, and the sink must occur in its input models. Run the same selection with `--verify` before measuring it:

```sh
zig build --build-file tools/build.zig writer-adapter -Doptimize=ReleaseFast
tools/zig-out/bin/z-xml-writer --verify \
    bench/shapes.tsv writer-attributes 16 unbuffered-sink
tools/zig-out/bin/z-xml-writer \
    bench/shapes.tsv writer-unchanged-text 1m buffered-sink
```

`buffered-sink` provides a 64 KiB caller-owned buffer; `unbuffered-sink` provides none. `one-byte-sink` and `short-sink` provide no buffer and accept at most one or seven bytes from each drain call. The adapter flushes the sink after each document. Normal runs discard accepted output. `--verify` stores it in a caller-owned capture buffer.

The JSON result records the selected shape, value, sink, semantic counts, output bytes, accepted bytes, sink calls, flushes, Writer allocation work, peak live Writer bytes, retained Writer capacity, caller input bytes, caller sink storage, and verification capture storage. `caller_oracle_storage_bytes` is the size of that output-capture buffer. Writer allocation fields exclude caller input, sink storage, and output capture. The adapter does not calculate checksums or write output files. Current Zebrac wrappers do not qualify the Writer lane.

## Zebrac measurement

Run generated correctness before timing. The qualification report must be newer than its target manifest, executable, corpus manifest, and input. A persistent command must match one qualified input model, consumer, chunk size, iteration count, and extra-argument row. A/A and matrix commands verify Zebrac's returned duration, sample counts, warmup count, command order, and failure policy. They remove an old index before running and publish a new index only after complete success. They require `prlimit` from util-linux to cap files written by Zebrac and its child commands.

This is the smallest event A/A check:

```sh
python3 tools/python/run-zebrac-aa.py \
    --manifest data/generated/z-xml-generated-v3/manifest.tsv \
    --eligibility ref/build/generated-corpus-results.tsv \
    --targets tools/targets.tsv \
    --bin-dir tools/zig-out/bin \
    --target z-xml-raw-reject \
    --workload text-1m \
    --output-dir data/results/zebrac-aa/text-1m
```

Measure the same qualified row and calculate its reports with:

```sh
python3 tools/python/run-zebrac-matrix.py \
    --manifest data/generated/z-xml-generated-v3/manifest.tsv \
    --eligibility ref/build/generated-corpus-results.tsv \
    --targets tools/targets.tsv \
    --bin-dir tools/zig-out/bin \
    --target z-xml-raw-reject \
    --lane event \
    --workload text-1m \
    --output-dir data/results/zebrac-matrix/text-1m

python3 tools/python/summarize-zebrac.py \
    --index data/results/zebrac-matrix/text-1m/index.json \
    --baseline event=z-xml-raw-reject \
    --output-dir data/results/zebrac-summary/text-1m
```

The scripts use `zebrac` from `PATH` by default. Pass `--zebrac PATH` only for an explicit override. Matrix-v2 and matrix-v3 results are historical evidence and are not accepted by the current summarizer.

`ref/build.sh` downloads and builds reference parsers in its local cache when needed.
