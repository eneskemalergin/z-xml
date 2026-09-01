# Tools

Status: **Active** (last updated: 2026-08-31)

`tools/` contains development commands and XML adapters. It is excluded from the Zig package.

Files are grouped by language. The Python commands are called through their configured interpreter, so they need no wrappers or package files.

- `build.zig` builds the Zig adapters and layout probe.
- `zig/` contains adapter source code compiled by `build.zig`.
- `python/` contains checks, generators, and measurement commands called through Python.
- `targets.tsv` describes the z-xml adapter capabilities used by fixture checks.
- `document-targets.tsv` declares owned-Document construction, traversal, and repeated-construction commands.
- `dtd-targets.tsv` declares the DTD baseline and no-DTD control commands.
- `validation-targets.tsv` declares fresh single-document and repeated-validation commands.
- `writer-targets.tsv` declares the one manifest-driven Writer adapter.
- `fetch-w3c-xmlconf.sh` downloads the pinned W3C suite. It stays at the root because it is the only shell command.

Use `make -C ref` for commands that work with fixtures, generated XML, or reference parsers. Use `zig build --build-file tools/build.zig` to build the z-xml adapters.

## Ownership map

The paths below are the complete tracked tool set. Python commands use their configured interpreter, the shell command runs directly, and `tools/build.zig` compiles only the Zig sources.

Build and declarations:

- `README.md` owns this command and file map. `plan/AGENTS.md` and `plan/ROADMAP.md` point developers here instead of duplicating tool details.
- `build.zig` owns the Zig tool build. Its callers are the documented `zig build --build-file tools/build.zig` commands. It imports the package module and the Zig tool sources, then installs adapters under `tools/zig-out/bin` or runs the layout probe and tool tests.
- `targets.tsv` declares the six z-xml Reader profiles used by `ref/check-corpus.sh`, `run-w3c-xmlconf.py`, `run-valgrind.py`, and `run-zebrac-matrix.py`. It has no output of its own.
- `document-targets.tsv` assigns the public owned-Document adapter to streamed construction, traversal, and repeated-construction lanes. Document qualification fixes each exact command used by measurement. The target file has no output of its own.
- `dtd-targets.tsv` assigns the DTD processing adapter and the process and reject no-DTD controls to separate measurement lanes. It has no output of its own.
- `validation-targets.tsv` assigns internal and caller-resolved adapters to fresh validation, then assigns fresh and reusable external-subset adapters to repeated validation. It has no output of its own.
- `persistent-targets.tsv` declares the protocol, consumer, memory, timing, transition, release, namespace, lane, and input-model support of the four z-xml resident or streamed adapters. It has no output of its own.
- `writer-targets.tsv` declares the protocol, oracle, sink, and memory-report support of `z-xml-writer`. `check-shape-matrix.py` checks its schema and exact target row.

Zig sources:

- `zig/check.zig` owns the single-file event-summary protocol. The `corpus-adapters` step builds six raw-name or namespace-aware DTD modes plus two fresh-validation baseline modes. Corpus and conformance commands pass an XML path; DTD modes resolve companion sources from that path. `--dtd-report` adds exact partial events, diagnostics, source results, and optional Reader and caller-source memory. Validation modes add validity, ordered finding work, identity counts, and grammar or per-document memory. The Reader and 64 KiB stream source remain unchanged. Each executable writes one JSON result to standard output.
- `zig/persistent.zig` owns Reader work over resident or streamed input. The `persistent-adapters` step builds raw-name, namespace-aware, default-Reader, and default-Reader namespace-summary executables. One Reader handles every iteration. `--next-file` and `--next-iterations` add a second input without replacing it. Optional timing, memory, and release reports separate source setup, Reader initialization, first and reset documents, parser allocation work, retained capacity, explicit release, and caller-owned input storage. The executable writes one JSON result.
- `zig/tree.zig` owns public `Document` construction, traversal, and repeated-construction measurement over a 64 KiB stream. The `tree-adapter` step builds `z-xml-tree`. Normal output reports node counts, depth, and common and complete-traversal checksums. `--namespaces=process` adds retained declarations and an expanded-name checksum. `--construction` builds and releases one Document without traversal. `--timing` starts traversal timing after construction; `--iterations=N` repeats that complete traversal after one build for profile attribution. `--memory` reports active and retained Document storage, growth slack, construction allocation work, an independent Reader-only pass, caller input storage, traversal scratch, and cleanup. `--repeat=N` creates and releases independent Documents; an optional next input adds a large-to-small phase, while verification, memory, and timing reports keep their work separate. Each mode writes one JSON result.
- `zig/writer.zig` owns manifest-selected public Writer work. The `writer-adapter` step builds `z-xml-writer`. It runs the attributes, unchanged-text, escaped-text, fragmented-text, namespace-depth, short-sink, and repeated-document shapes declared in `bench/shapes.tsv`. Each run writes one JSON result. `--verify` retains output for exact or Reader checks before measurement.
- `zig/validation_repeat.zig` owns fresh-versus-reused external DTD validation. The `validation-bench` step builds both modes. One Reader handles fixed repeated or large-then-small streamed schedules. Optional reports separate subset setup, document phases, immutable subset memory, Reader memory, resolver memory, release, and deinitialization. Each executable writes one JSON result.
- `zig/layout_probe.zig` owns development-only Reader and Document type-size output. The `layout` step runs it and prints tab-separated rows to standard error; it does not install an adapter.
- `zig/tracking_allocator.zig` is shared implementation for `persistent.zig`, `tree.zig`, `validation_repeat.zig`, and `writer.zig`. It has no command or build step of its own.

Generated inputs and declarations:

- `python/generate-byte-fixtures.py` owns the byte-sensitive files under `fixture/valid/encoding/` and `fixture/invalid/encoding/`. `make -C ref check-byte-fixtures`, `make -C ref check-corpus`, and `make -C ref check-reader-conformance` compare them without rewriting; direct generation rewrites only those files.
- `python/generate-unicode-normalization.py` owns `src/unicode_normalization.zig`. The Make targets call it through `UNICODE_PYTHON`. `make -C ref check-unicode-table` compares the table without rewriting; `make -C ref generate-unicode-table` rewrites it.
- `python/check-shape-matrix.py` checks ignored `bench/shapes.tsv`, `bench/oracles.tsv`, and `bench/full.tsv` against each other, `fixture/manifest.tsv`, and `writer-targets.tsv`. It rejects missing owners, incompatible lanes or input models, duplicate rows, invalid size plans, missing or changed Writer shapes, and Writer target drift. `make -C ref check-shape-matrix` prints a result and writes no file.
- `python/generate-benchmark-corpus.py` owns general generated XML, UTF-16 text, and its manifest under the selected ignored output directory. Generation writes the requested shapes, sizes, and rejection positions. Check mode requires the same workload-selection arguments and compares the exact row order, fields, file set, and generated bytes without rewriting. The `generate-corpus`, `generate-corpus-full`, `generate-corpus-persistent`, and `generate-corpus-document` Make targets call generation; the matching `verify-*` targets preserve that workload selection.
- `python/generate-namespace-benchmark.py` owns the namespace-churn XML and manifest under the selected ignored output directory. Check mode regenerates the requested corpus in a temporary directory and compares every file without rewriting the selected output. `make -C ref generate-namespace-corpus` generates it and `make -C ref verify-namespace-corpus` checks it.
- `python/generate-dtd-benchmark.py` owns the deterministic DTD processing corpus and exact result manifest under `data/generated/z-xml-dtd-generated-v1/`. It writes internal declarations, internal entities, resolved external sources, a no-DTD control, malformed and recursive inputs, resolver failures, and DTD, expansion, and external-source byte boundaries. Check mode regenerates the complete corpus in a temporary directory and compares its file set and bytes.
- `python/generate-validation-benchmark.py` owns the deterministic fresh-validation corpus and exact result manifest under `data/generated/z-xml-validation-generated-v1/`. It writes content-model, identity, caller-resolved external, invalid-finding, nondeterministic, malformed, unavailable-source, and content-position-limit workloads. Check mode regenerates the complete corpus in a temporary directory and compares its file set and bytes.
- `python/generate-validation-reuse.py` owns the deterministic repeated-validation corpus and exact result manifest under `data/generated/z-xml-validation-reuse-v1/`. It writes exact 16 KiB, 64 MiB, large-then-small, and invalid-finding schedules. Check mode regenerates the complete corpus in a temporary directory and compares its file set and bytes.
- `python/generate-document-repeat.py` owns schema `z-xml-document-repeat-v1`. It selects the existing 16 KiB and 64 MiB mixed-content inputs, fixes the small, large, and large-to-small counts and arguments, and writes one schedule manifest without copying XML. Check mode compares that manifest without rewriting it.

Correctness and conformance:

- `python/check-persistent-adapters.py` owns the small repeated-input protocol smoke check. It accepts z-xml artifacts, peer artifacts, or both; checks one resident schedule and three distinct stream schedules for both consumers; enforces input, output, and time limits; and writes no file. `make -C ref check-persistent` calls the peer selection through `ref/build.sh`.
- `python/check-generated-corpus.py` owns common-summary and owned-Document qualification. Its default mode checks declared event targets against the generated common summary. Explicit `--summary-lane subset` and `--summary-lane partial-dom` selections check reduced-work adapters without admitting them to the event or Document lane. Document mode requires named DOM targets, selected valid shapes, and the z-xml Document oracle. It checks complete traversal summaries, construction-only execution, one-traversal timing agreement, retained-memory reports, and allocator closure. `--document-operation` publishes the exact construction or traversal command accepted for later measurement. `--namespace` checks the namespace generator's independent counts and expanded-name checksum. Every mode checks each manifest file before applying the selection, bounds each adapter process, and publishes a result TSV only when every executed row passes.
- `python/check-generated-persistent.py` owns repeated-input, transition, and scale qualification for one declared persistent target. It checks the target lane, input model, consumer features, corpus identity, source schedules, semantic output, minimal and full consumer parity, process limits, optional phase timing, parser memory, caller input storage, and explicit release. It publishes its result TSV only when the complete run passes.
- `python/check-dtd-benchmark.py` owns DTD baseline qualification. It runs every exact command declared by the generated DTD manifest, checks semantic and memory reports separately, requires the expected status and complete JSON field set, checks Reader and caller-source cleanup, and publishes one event eligibility TSV only after all commands pass.
- `python/check-validation-benchmark.py` owns fresh-validation qualification. It bounds and runs every command declared by the validation manifest with and without memory reporting, checks exact validity, finding order, events, diagnostics, source results, identity counts, complete Reader memory accounting, and cleanup, then publishes one validation eligibility TSV only after all commands pass.
- `python/check-validation-reuse.py` owns repeated-validation qualification. It bounds and runs both fresh and reusable adapters for every fixed schedule, checks exact parity across iterations and modes, and verifies subset, Reader, resolver, timing, retained-capacity, release, and deinitialization fields before publishing eligibility.
- `python/check-document-repeat.py` owns repeated-Document qualification. It bounds and runs summary, semantic, memory, and timing modes for every fixed schedule, checks generated summaries, fresh versus post-large ownership, public-path and Reader allocation work, input identity, and deinitialization before publishing eligibility.
- `fetch-w3c-xmlconf.sh` owns the pinned W3C suite download and extraction under ignored `data/conformance/`. It checks the cached or downloaded archive, rejects unsafe archive paths, extracts through a temporary directory, and compares an existing destination with the pinned archive before reuse. `make -C ref fetch-xmlconf` calls it.
- `python/run-w3c-xmlconf.py` owns W3C catalog selection and parser-result classification. It follows the 21 manifests declared by the pinned root catalog and writes schema `z-xml-w3c-results-v1`. An absent W3C `VERSION` or `EDITION` is recorded as `all`. Every selected target and case has one `pass`, `fail`, `skip`, `mismatch`, `timeout`, or `tool-error` row. A skip keeps the W3C applicability class and gives a reason. A partial target in the validated lane admits valid DTD documents only; invalid and not-well-formed cases remain explicit `partial-validation` exclusions. External paths above the adapter's configured root require `external_parent_paths`. A complete report replaces the prior result atomically. Structural failures remove stale results. The command returns zero only when it records no failure, mismatch, timeout, or tool error. `make -C ref check-xmlconf` writes peer results; `make -C ref check-reader-conformance` writes separate z-xml results.

Resource and measurement commands:

- `python/run-valgrind.py` owns bounded Memcheck execution. Standalone mode checks one executable with an expected zero status. Corpus mode requires every selected target and case to have an exact passing correctness row. Both modes write logs and `metadata.json`; corpus mode also writes `results.tsv`. Metadata records the executable path and size, case, expected and observed status, semantic result, Valgrind result and error count, and descriptor counts. It does not report parser-owned memory or timing RSS.
- `python/run-zebrac-aa.py` owns A/A host-noise measurement for one exact qualified command. It derives the executable, primary input, and any companion or transition sources from their manifests, requires one fresh matching correctness row including exact program arguments, and writes raw output, logs, and schema `z-xml-zebrac-aa-v3` under `--output-dir`.
- `python/run-zebrac-matrix.py` owns correctness-qualified matched measurement. Repeated `--targets` and `--bin-dir` pairs place z-xml and peer commands in the same workload and lane group. It requires fresh common-summary, DTD, validation, repeated-Document, or exact persistent qualification, records companion and transition sources as measured inputs, and bounds Zebrac time and output. Normal runs write schema `z-xml-zebrac-matrix-v4`. `--reported-traversal-time` also runs the exact qualified timing commands in rotating order, requires one equal traversal result per sample, and writes schema `z-xml-zebrac-matrix-v5` with the post-build timing samples.
- `python/summarize-zebrac.py` owns whole-process Zebrac result calculation. It reads one or more matrix-v4 or matrix-v5 indexes plus one baseline per lane, validates matrix-v5 traversal records, then writes row, aggregate, JSON, and text reports under `--output-dir`. It rejects failed rows, unmatched work, lane drift, missing metrics, and wrong units. It does not turn adapter-reported traversal timing into process metrics, combine different lanes or measurement cases, or calculate aggregate ratios from incomplete workload coverage.

Generation, correctness, conformance, resource checking, and timing remain separate because they produce different evidence. `bench/` and `data/` are ignored. `bench/` contains local plans and small benchmark inputs. `data/` contains generated XML, downloaded test suites, and results. Benchmark results remain local until the reproduction and comparison commands are qualified.

## Generated correctness

Build the required z-xml adapters, verify the existing generated inputs without rewriting them, and run both correctness paths with:

```sh
make -C ref check-generated
make -C ref check-generated-persistent
make -C ref check-generated-document
make -C ref check-peer-events
make -C ref check-peer-persistent
make -C ref check-peer-document
make -C ref check-peer-limited
```

The first three commands check the declared z-xml event, persistent, and owned-Document modes. The remaining commands rebuild and check peer event, persistent, owned-Document, and reduced-work modes. Each command publishes results only after every executed row passes its exact oracle. Event, persistent, subset, and partial-DOM modes record unsupported features as exclusions. Document mode treats a missing required feature as a failed match. The limited command records lexical and structural-index adapters as out of profile because they do not produce the common XML summary.

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

## DTD processing baseline

Generate or verify the ignored DTD corpus, build the supported-target adapter, and qualify every command with:

```sh
python3 tools/python/generate-dtd-benchmark.py
python3 tools/python/generate-dtd-benchmark.py --check
zig build --build-file tools/build.zig corpus-adapters \
    -Dtarget=x86_64-linux -Doptimize=ReleaseFast \
    --prefix tmp/stage44/build
python3 tools/python/check-dtd-benchmark.py \
    --manifest data/generated/z-xml-dtd-generated-v1/manifest.tsv \
    --bin-dir tmp/stage44/build/bin \
    --results ref/build/dtd-processing-results.tsv
```

The generated manifest owns the exact external policy, limit arguments, expected status, semantic result, and companion source paths for each row. `check-dtd-benchmark.py` reruns each command with `--report-memory`; timing commands omit that flag.

Run an exact-binary A/A control for one qualified DTD command with:

```sh
python3 tools/python/run-zebrac-aa.py \
    --manifest data/generated/z-xml-dtd-generated-v1/manifest.tsv \
    --eligibility ref/build/dtd-processing-results.tsv \
    --targets tools/dtd-targets.tsv \
    --bin-dir tmp/stage44/build/bin \
    --target z-xml-dtd-process \
    --workload declarations-64m \
    --program-arg=--dtd-report \
    --program-arg=--external=forbid \
    --duration-ms 5000 --samples 20 --warmups 5 \
    --output-dir data/results/dtd-aa/declarations
```

Use the same target and arguments with `run-zebrac-matrix.py` for the one-command baseline. `external-resolve-64m` requires `--external=resolve`. `no-doctype-64m` compares `z-xml-dtd-process-control` and `z-xml-dtd-reject-control` together in lane `dtd-control`. Malformed, recursion, unavailable-source, and limit rows are correctness and bounded-resource checks, not speed rankings.

## DTD peer correctness

Run the DTD peer gate with:

```sh
make -C ref check-peer-validation
```

The command rebuilds libxml2 and Xerces, checks their declared focused validation constraints, and runs their W3C valid-DTD profiles. It writes separate focused and W3C results under `ref/build/`. Both peers are partial validators: unsupported validity constraints, XML editions, and external-resource modes remain recorded exclusions and are not eligible for timing. This gate does not claim complete DTD conformance.

## Fresh validation baseline

Generate or verify the ignored validation corpus, build the supported-target adapters, and qualify every command with:

```sh
python3 tools/python/generate-validation-benchmark.py
python3 tools/python/generate-validation-benchmark.py --check
zig build --build-file tools/build.zig corpus-adapters \
    -Dtarget=x86_64-linux -Doptimize=ReleaseFast \
    --prefix tmp/stage45/build
python3 tools/python/check-validation-benchmark.py \
    --manifest data/generated/z-xml-validation-generated-v1/manifest.tsv \
    --targets tools/validation-targets.tsv \
    --bin-dir tmp/stage45/build/bin \
    --results ref/build/fresh-validation-results.tsv
```

The generated manifest owns the target, external policy, limits, expected status, exact semantic result, and companion source paths. The qualifier reruns each command with `--report-memory`. Timing commands omit that flag.

Run an exact-binary A/A control for one qualified internal command with:

```sh
python3 tools/python/run-zebrac-aa.py \
    --manifest data/generated/z-xml-validation-generated-v1/manifest.tsv \
    --eligibility ref/build/fresh-validation-results.tsv \
    --targets tools/validation-targets.tsv \
    --bin-dir tmp/stage45/build/bin \
    --target z-xml-validation-internal \
    --workload models-64m \
    --duration-ms 5000 --samples 20 --warmups 5 \
    --output-dir data/results/validation-aa/models
```

Use the same target with `run-zebrac-matrix.py` for the content-model and identity baselines. Use `z-xml-validation-external` for `external-64m`. Invalid findings, nondeterministic models, malformed syntax, unavailable sources, and content-position limits are correctness and bounded-resource checks, not speed rankings.

## Validation reuse baseline

Generate or verify the repeated-validation corpus, build both adapters, and qualify every fixed schedule with:

```sh
python3 tools/python/generate-validation-reuse.py
python3 tools/python/generate-validation-reuse.py --check
zig build --build-file tools/build.zig validation-bench \
    -Dtarget=x86_64-linux -Doptimize=ReleaseFast \
    --prefix tmp/validation-reuse-build
python3 tools/python/check-validation-reuse.py \
    --manifest data/generated/z-xml-validation-reuse-v1/manifest.tsv \
    --targets tools/validation-targets.tsv \
    --bin-dir tmp/validation-reuse-build/bin \
    --results data/results/validation-reuse/eligibility.tsv
```

The manifest fixes the DTD name, document order, iteration counts, companion paths, and exact semantic results. The qualifier reruns each command with memory, timing, and explicit release enabled. Timing commands omit those reporting flags. Use the qualified program arguments unchanged with `run-zebrac-aa.py` or `run-zebrac-matrix.py`; pass work multipliers 4,096 for the small schedule, 8 for the large schedule, and 2 for the large-then-small schedule.

## Document construction baseline

Generate or verify the ignored Document inputs and qualify z-xml with:

```sh
make -C ref generate-corpus-document
make -C ref verify-corpus-document
make -C ref check-generated-document
```

The primary corpus contains exact 64 MiB attribute-heavy, mixed-content, and long-text documents plus the depth-256 guard. The namespace corpus contains one exact 64 MiB namespace-churn document. The separate 256 MiB long-text file must return status 3 because it exceeds the public general coalesced-text limit; it is not eligible for timing.

Document qualification runs normal summary, construction-only, timing, and memory modes. The raw summary is checked against the general generator. Namespace mode is also checked against the namespace generator's independent declaration count and expanded-name checksum. Memory output separates active owned bytes, capacity slack, temporary construction allocation work, final retained capacity, peak live bytes, an independent Reader-only pass, caller input storage, traversal scratch, and deinitialization.

Run one exact-binary control and baseline with the qualified construction arguments:

```sh
python3 tools/python/run-zebrac-aa.py \
    --manifest data/generated/z-xml-generated-v3-document/manifest.tsv \
    --eligibility ref/build/z-xml-document-results.tsv \
    --targets tools/document-targets.tsv \
    --bin-dir tools/zig-out/bin \
    --target z-xml-document \
    --workload attributes-varied-64m \
    --program-arg=--construction \
    --output-dir data/results/document-aa/attributes

python3 tools/python/run-zebrac-matrix.py \
    --manifest data/generated/z-xml-generated-v3-document/manifest.tsv \
    --eligibility ref/build/z-xml-document-results.tsv \
    --targets tools/document-targets.tsv \
    --bin-dir tools/zig-out/bin \
    --target z-xml-document --lane dom \
    --workload attributes-varied-64m \
    --program-arg=--construction \
    --output-dir data/results/document-baseline/attributes
```

Namespace construction also passes `--program-arg=--namespaces=process` and uses `ref/build/z-xml-document-namespace-results.tsv`. `make -C ref check-peer-document` qualifies normal and compact pugixml against the same raw retained summary and traversal preparation. Pugixml remains a separate whole-file diagnostic; its source model does not match z-xml's streamed input.

## Document traversal baseline

Use the same generated Document inputs and oracle checks. Add `--document-operation traversal` when producing the traversal eligibility files. The qualified program arguments are `--timing` for raw documents and `--timing --namespaces=process` for the namespace document.

Run `run-zebrac-aa.py` on each z-xml priority command. Run `run-zebrac-matrix.py` with `--reported-traversal-time` for the matched baseline:

```sh
python3 tools/python/run-zebrac-matrix.py \
    --manifest data/generated/z-xml-generated-v3-document/manifest.tsv \
    --eligibility data/results/document-traversal/eligibility.tsv \
    --targets tools/document-targets.tsv \
    --bin-dir tools/zig-out/bin \
    --target z-xml-document --lane dom \
    --workload attributes-varied-64m \
    --program-arg=--timing --reported-traversal-time \
    --output-dir data/results/document-traversal/baseline
```

Zebrac metrics cover the complete command because Zebrac has no setup boundary. The matrix-v5 `reported_traversal` field is the post-build traversal baseline. Each reported sample performs one traversal and checks the exact element count and checksum. Use `--timing --iterations=N` only to make traversal dominate a profile after one build; it is not an accepted one-traversal baseline command.

## Repeated Document construction baseline

Generate the schedule from the existing 16 KiB and 64 MiB mixed-content corpora, build the adapter, and qualify all three schedules with:

```sh
python3 tools/python/generate-document-repeat.py
python3 tools/python/generate-document-repeat.py --check
zig build --build-file tools/build.zig tree-adapter \
    -Dtarget=x86_64-linux -Doptimize=ReleaseFast \
    --prefix tmp/stage50/build
python3 tools/python/check-document-repeat.py \
    --manifest data/generated/z-xml-document-repeat-v1.tsv \
    --targets tools/document-targets.tsv \
    --bin-dir tmp/stage50/build/bin \
    --results data/results/document-repeat/eligibility.tsv
```

The fixed schedules are 4,096 small Documents, eight large Documents, and one large followed by 4,096 small Documents. The qualifier runs summary, semantic verification, memory, and reported timing modes. Memory output separates full `parseDocument` allocation work from an independent Reader-only pass and requires zero live bytes after every deinitialization. The large-to-small schedule requires the final small ownership guard and retained capacity to match the fresh small schedule.

Use the manifest arguments unchanged for Zebrac. The exact work multipliers are 4,096 for `document-repeat-small`, 8 for `document-repeat-large`, and 2 for `document-repeat-large-small`. One small baseline command is:

```sh
python3 tools/python/run-zebrac-matrix.py \
    --manifest data/generated/z-xml-document-repeat-v1.tsv \
    --eligibility data/results/document-repeat/eligibility.tsv \
    --targets tools/document-targets.tsv \
    --bin-dir tmp/stage50/build/bin \
    --target z-xml-document-repeat --lane document-repeat \
    --workload document-repeat-small \
    --program-arg=--repeat=4096 --work-multiplier=4096 \
    --duration-ms 5000 --samples 20 --warmups 5 \
    --output-dir data/results/document-repeat/baseline-small
```

`run-zebrac-aa.py` accepts the same manifest, eligibility, target, workload, and program arguments. It does not take a work multiplier. Build with `-Dstrip=false` and pass the same qualified command to `perf record` for profile attribution.

## Build commands

Every Zig adapter imports `z_xml`, the public package root, through `tools/build.zig`.

The persistent adapter gives resident input to `Reader` as one slice. `--chunk-bytes` sizes one shared file-reader buffer for stream input. The resident result keeps the requested value in its protocol metadata, so resident rows with different chunk values are not different source schedules. Transition runs load both resident inputs or reuse the one stream buffer. `caller_input_storage_bytes` reports that storage separately from Reader memory.

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

ReleaseFast adapters are stripped by default. Pass `-Dstrip=false` only when a profiler needs symbols.

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
