# Tools

Status: **Active** (last updated: 2026-09-01)

`tools/` contains development commands and XML adapters. It is excluded from the Zig package.

Files are grouped by language. The Python commands are called through their configured interpreter, so they need no wrappers or package files.

- `build.zig` builds the Zig adapters and layout probe.
- `zig/` contains adapter source code compiled by `build.zig`.
- `python/` contains checks, generators, measurement commands, and three support modules imported by those commands.
- `targets.tsv` describes the z-xml adapter capabilities used by fixture checks.
- `document-targets.tsv` declares owned-Document construction, traversal, and repeated-construction commands.
- `dtd-targets.tsv` declares the DTD baseline and no-DTD control commands.
- `validation-targets.tsv` declares fresh single-document and repeated-validation commands.
- `persistent-targets.tsv` declares repeated-input Reader commands.
- `writer-targets.tsv` declares the one manifest-driven Writer adapter.
- `fetch-w3c-xmlconf.sh` downloads the pinned W3C suite. It stays at the root because it is the only shell command.

Use `make -C ref` for commands that work with fixtures, generated XML, or reference parsers. Use `zig build --build-file tools/build.zig` to build the z-xml adapters.

## Ownership map

The implementation and declaration set contains 39 files: 21 Python commands, 3 Python support modules, 7 Zig files, 6 target manifests, 1 shell command, and 1 build file. This README is the 40th project file under `tools/` and owns the map. A command entry is its CLI or build step. A declaration entry is its manifest path. Support modules enter through imports. Each item names its input, output, entry path or caller, and focused check. An unversioned result is identified by the exact field constant that owns its header.

Build and declarations:

- `README.md` owns this command and file map. `plan/AGENTS.md` and `plan/ROADMAP.md` point developers here instead of duplicating tool details. Comparing this map with `rg --files tools` is its focused check.
- `build.zig` owns the `zig build --build-file tools/build.zig STEP` entry. It reads the package source and Zig tool sources, then installs adapters under the selected prefix, runs tool tests, or prints the layout probe. It has no persisted schema or result output. `tools/README.md` documents every step, and `ref/Makefile` calls the corpus, persistent, and tree adapter steps. `zig build --build-file tools/build.zig test -Dtarget=x86_64-linux --summary all` is its focused check.
- `targets.tsv` is the `z-xml-targets-v1` declaration entry for six Reader profiles. `ref/check-corpus.sh`, `check-generated-corpus.py`, `run-w3c-xmlconf.py`, `run-valgrind.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` read it; it writes nothing. `make -C ref check-reader-conformance` is its complete profile check after `corpus-adapters` is built.
- `document-targets.tsv` is the `z-xml-targets-v1` declaration entry for streamed Document construction, traversal, and repeated construction. `check-generated-corpus.py`, `check-document-repeat.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` read it; it writes nothing. `make -C ref check-generated-document` checks the normal rows, and the repeated Document qualification command below checks the repeat row.
- `dtd-targets.tsv` is the `z-xml-targets-v1` declaration entry for DTD processing and its two no-DTD controls. `check-dtd-benchmark.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` read it; it writes nothing. The DTD processing qualification command below is its focused check.
- `validation-targets.tsv` is the `z-xml-targets-v1` declaration entry for fresh internal or caller-resolved validation and fresh or reusable repeated validation. `check-validation-benchmark.py`, `check-validation-reuse.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` read it; it writes nothing. The fresh and reuse qualification commands below check all four rows.
- `persistent-targets.tsv` is the `z-xml-persistent-targets-v1` declaration entry for the four resident or streamed Reader adapters. `check-generated-persistent.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` read it; it writes nothing. `make -C ref check-generated-persistent` is its focused check.
- `writer-targets.tsv` is the `z-xml-writer-targets-v1` declaration entry for the manifest-driven Writer adapter. `check-shape-matrix.py` and `run-zebrac-aa.py` read it; it writes nothing. `make -C ref check-shape-matrix` is its focused declaration check.

Zig sources:

- `zig/check.zig` enters through the eight executables built by `corpus-adapters`. It reads one XML path plus report, external-source, and limit flags. DTD modes resolve companion sources relative to the XML path. The six Reader profiles write an unversioned common-summary JSON result. `--dtd-report` adds partial events, diagnostics, source results, and optional Reader and caller-source memory. Validation reports add validity, ordered finding work, identity counts, and grammar or per-document memory. All modes keep the same public Reader and 64 KiB stream source. `ref/check-corpus.sh`, `check-generated-corpus.py`, `check-dtd-benchmark.py`, `check-validation-benchmark.py`, `run-w3c-xmlconf.py`, `run-valgrind.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` call its executables. `make -C ref check-reader-conformance` and the DTD and validation qualification commands below are its focused protocol checks.
- `zig/persistent.zig` enters through the four executables built by `persistent-adapters`. It reads one resident or streamed XML path, an optional transition path, and schedule or report flags. One Reader handles every iteration; `--next-file` and `--next-iterations` add a second input without replacing it. Optional timing, memory, and release reports separate source setup, Reader initialization, first and reset documents, allocation work, retained capacity, explicit release, and caller-owned input storage. It writes one unversioned persistent-protocol JSON result to standard output. `check-persistent-adapters.py`, `check-generated-persistent.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` call its executables. `make -C ref check-generated-persistent` is its focused check.
- `zig/tree.zig` enters through `z-xml-tree`, built by `tree-adapter`. It reads one streamed XML path or a fixed repeated-construction schedule. Summary mode reports node counts, depth, and common and complete-traversal checksums; namespace mode adds retained declarations and an expanded-name checksum. Construction mode omits traversal. Timing starts after construction, and `--iterations=N` repeats traversal only for profile attribution. Memory mode separates Document storage, growth slack, construction allocation work, an independent Reader pass, caller input, traversal scratch, and cleanup. Repeat mode creates and releases independent Documents and can add a large-to-small phase. It writes one unversioned JSON result per mode. `check-generated-corpus.py`, `check-document-repeat.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` call it. `make -C ref check-generated-document` and the repeated Document qualification command below are its focused checks.
- `zig/writer.zig` enters through `z-xml-writer`, built by `writer-adapter`. It reads `bench/shapes.tsv`, one shape, one value, one sink, and optional verification or repeat flags. It owns the attribute, unchanged-text, escaped-text, fragmented-text, namespace-depth, short-sink, and repeated-document shapes. It writes `z-xml-writer-result-v1` or `z-xml-writer-repeat-result-v1` JSON to standard output and never writes XML files. `--verify` retains output only for exact or Reader checks before measurement. Direct verification and the A/A wrapper are its callers. The first `--verify` command under Writer measurement is its focused check.
- `zig/validation_repeat.zig` enters through `z-xml-validation-fresh` and `z-xml-validation-reused`, built by `validation-bench`. It reads an external DTD, one streamed XML path, an optional transition path, and schedule or report flags. One Reader handles each fixed repeated or large-to-small schedule. Optional reports separate subset setup, document phases, immutable subset memory, Reader memory, resolver memory, release, and deinitialization. It writes one unversioned validation-reuse JSON result to standard output. `check-validation-reuse.py`, `run-zebrac-aa.py`, and `run-zebrac-matrix.py` call its executables. The validation reuse qualification command below is its focused check.
- `zig/layout_probe.zig` enters through the `layout` build step. It reads the compiled Reader and Document types and prints unversioned tab-separated size rows to standard error without installing an adapter. `zig build --build-file tools/build.zig layout -Dtarget=x86_64-linux` is its focused check.
- `zig/tracking_allocator.zig` enters through the imported `TrackingAllocator` type. It has no CLI, persisted schema, or output. `check.zig`, `persistent.zig`, `tree.zig`, `validation_repeat.zig`, and `writer.zig` are its five callers. The development tool test step is its focused check.

Generated inputs and declarations:

- `python/generate-byte-fixtures.py` enters as a direct command and through `check-byte-fixtures`. It reads its fixed byte definitions and writes only the byte-sensitive files under `fixture/valid/encoding/` and `fixture/invalid/encoding/`; `fixture/manifest.tsv` classifies them under `z-xml-fixtures-v3`. `make -C ref check-byte-fixtures` is its no-write focused check.
- `python/generate-unicode-normalization.py` enters through `generate-unicode-table` or `check-unicode-table`. It reads Python's Unicode database, requires version 15.1, and writes `src/unicode_normalization.zig`; it has no separate data schema. `make -C ref check-unicode-table` is its no-write focused check.
- `python/check-shape-matrix.py` enters through `check-shape-matrix`. It reads `z-xml-shape-matrix-v1`, `z-xml-oracles-v1`, `z-xml-benchmark-plan-v1`, `z-xml-fixtures-v3`, and `z-xml-writer-targets-v1`, prints one result, and writes no file. `make -C ref check-shape-matrix` is its focused check.
- `python/generate-benchmark-corpus.py` enters through the `generate-corpus*` and `verify-corpus*` Make targets. It reads workload-selection flags and optional `z-xml-benchmark-plan-v1`, then writes selected shapes, sizes, optional depth and rejection cases, UTF-16 text, and a `z-xml-generated-v3` manifest under one output directory. Check mode requires the same workload selection and compares row order, fields, file set, and bytes without rewriting. The matching `verify-corpus*` target is the focused check for each selected corpus.
- `python/generate-namespace-benchmark.py` enters through the namespace generation and verification Make targets. It reads exact sizes and writes namespace-churn XML plus a `z-xml-namespace-benchmark-v1` manifest under one output directory. Check mode regenerates into a temporary directory and compares the complete file set without rewriting the selected output. `make -C ref verify-namespace-corpus` is its focused check.
- `python/generate-dtd-benchmark.py` is the direct DTD generator entry. It reads no external source data and writes the complete `z-xml-dtd-generated-v1` corpus and manifest. `python3 tools/python/generate-dtd-benchmark.py --check` is its no-write focused check.
- `python/generate-validation-benchmark.py` is the direct fresh-validation generator entry. It reads no external source data and writes the complete `z-xml-validation-generated-v1` corpus and manifest. `python3 tools/python/generate-validation-benchmark.py --check` is its no-write focused check.
- `python/generate-validation-reuse.py` is the direct repeated-validation generator entry. It reads no external source data and writes the complete `z-xml-validation-reuse-v1` corpus and manifest. `python3 tools/python/generate-validation-reuse.py --check` is its no-write focused check.
- `python/generate-document-repeat.py` is the direct repeated-Document schedule entry. It reads existing `z-xml-generated-v3` manifests and writes one `z-xml-document-repeat-v1` schedule without copying XML. `python3 tools/python/generate-document-repeat.py --check` is its no-write focused check.

Python support modules:

- `python/generated_tree.py` owns the temporary-tree build, exact file-set and byte comparison, no-write check, completed-tree replacement, and fixed-byte writers shared by the DTD and validation corpus generators. It has no command, schema, or output of its own. The three importing generator check modes are its focused checks.
- `python/qualification_io.py` owns bounded control-file reads, the two established duplicate-field JSON decoders, full file identities, and completed TSV replacement shared by correctness qualifiers. It has no command, schema, or output of its own. The importing generated-corpus, persistent, DTD, validation, validation-reuse, and repeated-Document qualifiers are its focused checks.
- `python/zebrac_measurement.py` owns Zebrac lookup, bounded protocol reads, three-field file identity, persistent argument splitting, bounded child execution, and Git source identity shared by the A/A and matrix commands. It has no command, schema, correctness decision, or output of its own. The smallest A/A and matrix commands below are its focused checks.

Correctness and conformance:

- `python/check-persistent-adapters.py` enters directly or through `ref/build.sh persistent`. It reads installed peer or z-xml adapters and one bounded smoke input, then checks one resident and three stream schedules for minimal and full consumers. It bounds input size, process output, and run time, prints pass or fail, and writes no result file. `python3 tools/python/check-persistent-adapters.py --z-xml-bin-dir tools/zig-out/bin` is its focused z-xml check.
- `python/check-generated-corpus.py` enters through generated event, limited, and Document Make targets. It reads a `z-xml-generated-v3` or `z-xml-namespace-benchmark-v1` manifest, `z-xml-targets-v1` or `z-xml-targets-v2` declarations, installed adapters, and an optional Document oracle. Event mode checks the common summary. Explicit subset and partial-DOM modes remain outside event and Document eligibility. Document mode checks complete traversal, construction-only execution, one-traversal timing, retained memory, and allocator closure. Namespace mode also checks independent declaration counts and expanded-name checksums. Every mode validates the complete manifest before selection, bounds each process, and atomically publishes an unversioned eligibility TSV whose exact header is its mode-specific `fieldnames` list only after every executed row passes. `make -C ref check-generated` and `make -C ref check-generated-document` are its focused event and Document checks.
- `python/check-generated-persistent.py` enters through generated persistent and Reader scale Make targets. It reads a generated or namespace manifest, one `z-xml-persistent-targets-v1` declaration, one installed adapter, and one exact schedule. It checks lane, input model, consumer features, corpus identity, source schedules, semantic output, consumer parity, process limits, optional timing, parser memory, caller input storage, and explicit release. It atomically publishes an unversioned eligibility TSV whose exact header is `RESULT_FIELDS` plus enabled report fields only after the complete run passes. `make -C ref check-generated-persistent` is its focused check.
- `python/check-dtd-benchmark.py` is the direct DTD qualification entry. It reads `z-xml-dtd-generated-v1`, `z-xml-targets-v1`, and installed adapters. It runs every manifest command with separate semantic and memory reports, requires the expected status and complete JSON fields, and checks Reader and caller-source cleanup. It atomically publishes an unversioned eligibility TSV with header `RESULT_FIELDS` only after all commands pass. The DTD processing qualification command below is its focused check.
- `python/check-validation-benchmark.py` is the direct fresh-validation qualification entry. It reads `z-xml-validation-generated-v1`, `z-xml-targets-v1`, and installed adapters. It bounds every command with and without memory reporting and checks validity, finding order, events, diagnostics, source results, identity counts, Reader memory, and cleanup. It atomically publishes an unversioned eligibility TSV with header `RESULT_FIELDS` only after all commands pass. The fresh validation qualification command below is its focused check.
- `python/check-validation-reuse.py` is the direct repeated-validation qualification entry. It reads `z-xml-validation-reuse-v1`, `z-xml-targets-v1`, and both installed adapters. It bounds every fixed schedule, checks parity across iterations and modes, and verifies subset, Reader, resolver, timing, capacity, release, and deinitialization fields. It atomically publishes an unversioned eligibility TSV with header `RESULT_FIELDS` only after all commands pass. The validation reuse qualification command below is its focused check.
- `python/check-document-repeat.py` is the direct repeated-Document qualification entry. It reads `z-xml-document-repeat-v1`, `z-xml-targets-v1`, and `z-xml-tree`. It bounds summary, semantic, memory, and timing runs, then checks generated summaries, fresh versus post-large ownership, public-path and Reader allocation work, input identity, and deinitialization. It atomically publishes an unversioned eligibility TSV with header `RESULT_FIELDS` only after all schedules pass. The repeated Document qualification command below is its focused check.
- `fetch-w3c-xmlconf.sh` enters through `make -C ref fetch-xmlconf`. It reads the pinned archive from its cache or W3C, checks its digest and paths, and publishes the extracted suite under `data/conformance/`; it has no result schema. Re-running `make -C ref fetch-xmlconf` against the pinned cache is its focused check.
- `python/run-w3c-xmlconf.py` enters through peer or Reader conformance Make targets. It reads the pinned W3C catalog, follows its 21 manifests, and runs declared installed adapters. Every target and case receives one `pass`, `fail`, `skip`, `mismatch`, `timeout`, or `tool-error` row. Skips keep the W3C applicability class and a reason. Partial validated targets admit valid DTD documents only; other classes remain explicit exclusions. External paths above the configured root require `external_parent_paths`. A complete run atomically publishes `z-xml-w3c-results-v1`; structural failure removes stale results, and the command returns zero only with no failure, mismatch, timeout, or tool error. `make -C ref check-reader-conformance` is its focused z-xml check; `make -C ref check-xmlconf` checks peers.

Resource and measurement commands:

- `python/run-valgrind.py` is the bounded Memcheck entry. It reads one standalone executable or a supported manifest, fresh eligibility TSV, target declarations, and installed adapters. Standalone mode expects status zero; corpus mode requires an exact passing correctness row for every selected command. It writes bounded per-case logs, `z-xml-valgrind-v4` metadata, and an unversioned corpus `results.tsv` with header `RESULT_FIELDS`. Metadata keeps semantic status, process status, Valgrind status, error counts, and descriptor counts separate; it does not claim parser-owned bytes or timing RSS. The `/usr/bin/true` and `/usr/bin/false` commands below are its focused pass and failure checks.
- `python/run-zebrac-aa.py` is the one-command A/A entry. It reads one supported workload manifest, fresh eligibility TSV, target declarations, an installed executable, and exact program arguments. It derives companion and transition sources from the manifest and rejects stale or mismatched qualification. It writes bounded raw output, logs, and `z-xml-zebrac-aa-v3` under `--output-dir`. The smallest event A/A command below is its focused check; `--dry-run` checks qualification without timing.
- `python/run-zebrac-matrix.py` is the matched measurement entry. It reads one supported workload manifest, one or more fresh eligibility reports, matching target declarations and binary directories, exact lanes, and program arguments. Repeated target and binary pairs keep z-xml and peers in one workload group. Companion and transition sources are measured inputs. It writes bounded raw output and `z-xml-zebrac-matrix-v4`; reported traversal mode rotates exact qualified commands, requires equal traversal results per sample, and writes `z-xml-reported-traversal-v1` records inside `z-xml-zebrac-matrix-v5`. The smallest event matrix command below is its focused check; `--dry-run` checks qualification without timing.
- `python/summarize-zebrac.py` is the result calculation entry. It reads `z-xml-zebrac-matrix-v4` or `z-xml-zebrac-matrix-v5` indexes and one baseline per lane, validates traversal records, and writes `z-xml-zebrac-summary-v1` row, aggregate, JSON, and text reports under `--output-dir`. It rejects failed rows, unmatched work, lane drift, missing metrics, and wrong units. It does not mix lanes, treat adapter traversal time as a process metric, or calculate aggregate ratios from incomplete coverage. The summary command below is its focused check.

Generation, correctness, conformance, resource checking, and timing remain separate because they produce different evidence. `bench/` and `data/` are ignored. `bench/` contains local plans and small benchmark inputs. `data/` contains generated XML, downloaded test suites, and results. Benchmark results remain local until the reproduction and comparison commands are qualified.

## Generated correctness

Build the required z-xml adapters, verify the existing generated inputs without rewriting them, and run the correctness paths with:

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
    --prefix tmp/dtd-baseline/build
python3 tools/python/check-dtd-benchmark.py \
    --manifest data/generated/z-xml-dtd-generated-v1/manifest.tsv \
    --bin-dir tmp/dtd-baseline/build/bin \
    --results ref/build/dtd-processing-results.tsv
```

The generated manifest owns the exact external policy, limit arguments, expected status, semantic result, and companion source paths for each row. `check-dtd-benchmark.py` reruns each command with `--report-memory`; timing commands omit that flag.

Run an exact-binary A/A control for one qualified DTD command with:

```sh
python3 tools/python/run-zebrac-aa.py \
    --manifest data/generated/z-xml-dtd-generated-v1/manifest.tsv \
    --eligibility ref/build/dtd-processing-results.tsv \
    --targets tools/dtd-targets.tsv \
    --bin-dir tmp/dtd-baseline/build/bin \
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
    --prefix tmp/validation-baseline/build
python3 tools/python/check-validation-benchmark.py \
    --manifest data/generated/z-xml-validation-generated-v1/manifest.tsv \
    --targets tools/validation-targets.tsv \
    --bin-dir tmp/validation-baseline/build/bin \
    --results ref/build/fresh-validation-results.tsv
```

The generated manifest owns the target, external policy, limits, expected status, exact semantic result, and companion source paths. The qualifier reruns each command with `--report-memory`. Timing commands omit that flag.

Run an exact-binary A/A control for one qualified internal command with:

```sh
python3 tools/python/run-zebrac-aa.py \
    --manifest data/generated/z-xml-validation-generated-v1/manifest.tsv \
    --eligibility ref/build/fresh-validation-results.tsv \
    --targets tools/validation-targets.tsv \
    --bin-dir tmp/validation-baseline/build/bin \
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
    --prefix tmp/document-repeat/build
python3 tools/python/check-document-repeat.py \
    --manifest data/generated/z-xml-document-repeat-v1.tsv \
    --targets tools/document-targets.tsv \
    --bin-dir tmp/document-repeat/build/bin \
    --results data/results/document-repeat/eligibility.tsv
```

The fixed schedules are 4,096 small Documents, eight large Documents, and one large followed by 4,096 small Documents. The qualifier runs summary, semantic verification, memory, and reported timing modes. Memory output separates full `parseDocument` allocation work from an independent Reader-only pass and requires zero live bytes after every deinitialization. The large-to-small schedule requires the final small ownership guard and retained capacity to match the fresh small schedule.

Use the manifest arguments unchanged for Zebrac. The exact work multipliers are 4,096 for `document-repeat-small`, 8 for `document-repeat-large`, and 2 for `document-repeat-large-small`. One small baseline command is:

```sh
python3 tools/python/run-zebrac-matrix.py \
    --manifest data/generated/z-xml-document-repeat-v1.tsv \
    --eligibility data/results/document-repeat/eligibility.tsv \
    --targets tools/document-targets.tsv \
    --bin-dir tmp/document-repeat/build/bin \
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
zig build --build-file tools/build.zig writer-adapter \
    -Dtarget=x86_64-linux -Doptimize=ReleaseFast
zig build --build-file tools/build.zig validation-bench -Doptimize=ReleaseFast
zig build --build-file tools/build.zig reader-audit \
    -Dtarget=x86_64-linux -Doptimize=ReleaseFast
zig build --build-file tools/build.zig layout -Doptimize=ReleaseFast
```

ReleaseFast adapters are stripped by default. Pass `-Dstrip=false` only when a profiler needs symbols.

Check the benchmark plans and the z-xml repeated-input protocol with:

```sh
make -C ref check-shape-matrix
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
python3 tools/python/check-persistent-adapters.py --z-xml-bin-dir tools/zig-out/bin
```

`zig build --build-file tools/build.zig tools -Doptimize=ReleaseFast` installs every adapter. The built-in `install` step calls `tools`. The `test` step runs tests for the tool code. The separate `reader-audit` step installs the Reader test executable used for Memcheck; it is not part of the adapter union.

Run that executable under Memcheck with:

```sh
python3 tools/python/run-valgrind.py \
    --output-dir data/results/reader-audit \
    --standalone tools/zig-out/bin/z-xml-reader-audit
```

Use the stripped ReleaseFast audit built above. Unstripped Zig debug information can overflow the bounded log with decoder warnings, and Debug stack probes can be reported as invalid reads before the tested function adjusts its stack pointer.

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

The Reader audit runs the 68 tests selected by its `[Reader` filter under Memcheck with the same stack-based Reader storage used by normal tests and fuzz campaigns.

The development build installs adapters under `tools/zig-out/bin` by default.

## Writer measurement

The Writer adapter accepts `MANIFEST SHAPE VALUE SINK`. The selected row must be a ready Writer row, the value must occur in its size plan, and the sink must occur in its input models. `writer-repeated-documents` uses its selected value as the number of fresh Writer instances. `writer-unchanged-text` accepts `--repeat=N` and an optional complete `--next-value=VALUE --next-repeat=N` transition. No other shape accepts repeat options. Run the same selection with `--verify` before measuring it:

```sh
zig build --build-file tools/build.zig writer-adapter \
    -Dtarget=x86_64-linux -Doptimize=ReleaseFast
tools/zig-out/bin/z-xml-writer --verify \
    bench/shapes.tsv writer-attributes 16 unbuffered-sink
tools/zig-out/bin/z-xml-writer \
    bench/shapes.tsv writer-unchanged-text 1m buffered-sink

tools/zig-out/bin/z-xml-writer --verify \
    bench/shapes.tsv writer-repeated-documents 4096 buffered-sink
tools/zig-out/bin/z-xml-writer --verify \
    bench/shapes.tsv writer-unchanged-text 64m buffered-sink --repeat=8
tools/zig-out/bin/z-xml-writer --verify \
    bench/shapes.tsv writer-unchanged-text 64m buffered-sink \
    --repeat=1 --next-value=16k --next-repeat=4096
```

`buffered-sink` provides a 64 KiB caller-owned buffer; `unbuffered-sink` provides none. `one-byte-sink` and `short-sink` provide no buffer and accept at most one or seven bytes from each drain call. The adapter flushes the sink after each document. Normal runs discard accepted output. Single-document `--verify` runs store the complete output in a caller-owned capture buffer. Repeated runs reuse one capture buffer sized for the largest single document and verify each document before the next Writer starts.

The normal JSON schema is `z-xml-writer-result-v1`. It records the selected shape, value, sink, semantic counts, output bytes, accepted bytes, sink calls, flushes, Writer allocation work, peak live Writer bytes, retained Writer capacity, caller input bytes, caller sink storage, and verification capture storage. Repeated runs use `z-xml-writer-repeat-result-v1`, split a large-then-small schedule into primary and next phases, and add retained-capacity total. `caller_oracle_storage_bytes` is the size of the output-capture buffer. Writer allocation fields exclude caller input, sink storage, and output capture. The adapter does not calculate checksums or write output files.

`run-zebrac-aa.py` accepts the Writer target and shape matrix. Pass the selected value and sink as the first two program arguments, followed by any repeat options. The eligibility report uses the event columns plus `program_args`; one shape may have several rows when the exact schedule differs. Publish a row only after the same selection passes `--verify`, and write the report after the shape matrix, target declaration, and executable are final. Before starting Zebrac, the wrapper reruns that exact selection with `--verify` and checks its result. A `pass` row alone cannot admit incorrect Writer output.

```sh
python3 tools/python/run-zebrac-aa.py \
    --manifest bench/shapes.tsv \
    --eligibility data/results/writer/eligibility.tsv \
    --targets tools/writer-targets.tsv \
    --bin-dir tools/zig-out/bin \
    --target z-xml-writer \
    --workload writer-attributes \
    --program-arg 256 \
    --program-arg buffered-sink \
    --output-dir data/results/writer/aa/attributes-buffered
```

The A/A wrapper places the shape manifest before the selected shape, value, and sink, matching the adapter contract. The peer matrix remains file-input only. Writer has no eligible peer, so no unmatched matrix lane is added.

## Zebrac measurement

Run generated correctness before timing. The qualification report must be newer than its target manifest, executable, corpus manifest, and input. A persistent command must match one qualified input model, consumer, chunk size, iteration count, and extra-argument row. A/A and matrix commands verify Zebrac's returned duration, sample counts, warmup count, command order, and failure policy. They remove an existing index before running and publish a new index only after complete success. They require `prlimit` from util-linux to cap files written by Zebrac and its child commands.

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

The scripts use `zebrac` from `PATH` by default. Pass `--zebrac PATH` only for an explicit override.

`ref/build.sh` downloads and builds reference parsers in its local cache when needed.
