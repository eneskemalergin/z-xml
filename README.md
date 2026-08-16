# z-xml

Status: **Active** (last updated: 2026-08-15)

`z-xml` is a benchmark-led effort to build a complete, lightweight, high-performance XML library for Zig 0.16. The target includes compile-time-specialized streaming readers, XML namespaces, UTF-8 and UTF-16, complete non-validating DTD behavior, optional DTD validation, XML 1.1 compatibility, and a compact owned DOM. Conformance data, matched workloads, and reproducible peer builds keep correctness and performance decisions measurable.

The repository now contains the compiled reader type factory, lifecycle, specialized event and diagnostic shapes, whole-slice and buffered-I/O adapters, push drain, layout probe, general ASCII-named element structure, and atomic source attributes. The current reader accepts nested ordinary and empty elements plus source-ordered ASCII attributes whose values need no normalization or reference processing. It preserves event lifetimes and bounds active depth, open names, attribute count, attribute bytes, individual names and values, and complete start tags. This is implementation evidence, not a general XML parser claim. Text, Unicode, references, normalization, declarations, namespaces, encodings, DTD behavior, validation, and the tree follow the gates in [`plan/ROADMAP.md`](plan/ROADMAP.md).

Build the current library checks with the pinned compiler:

```sh
./zig-0.16.0/zig build test
./zig-0.16.0/zig build test -Doptimize=ReleaseFast
./zig-0.16.0/zig build layout -Doptimize=ReleaseFast
```

The reference laboratory in [`ref/`](ref/README.md), the checked-in valid and invalid corpus in [`fixture/`](fixture/README.md), and the measurement tooling qualify each expansion. The standards boundary, evidence, reader and validation contracts, compact tree, performance targets, and staged architecture live in [`plan/design/`](plan/design/README.md).

Build every reference and run the focused correctness gate:

```sh
make -C ref check-corpus
```

Build and verify the host-tuned binaries and deterministic performance corpus before zebrac:

```sh
make -C ref TUNE=native audit-build smoke check-corpus check-generated
```

Generate and verify the full 1 MiB through 1 GiB matrix separately. It occupies about 10.3 GiB and is not committed:

```sh
make -C ref TUNE=native generate-corpus-full verify-corpus-full
```

Build and verify the persistent Expat and quick-xml protocols plus their 1, 16, 64, and 256 KiB inputs:

```sh
make -C ref TUNE=native persistent-smoke generate-corpus-persistent
```

Fetch and audit the official W3C XML Test Suite separately:

```sh
make -C ref check-xmlconf
```

The W3C audit currently exposes known reference-parser disagreements and exits nonzero. This is intentional. Generated and real benchmark artifacts are not committed, and zebrac measurements wait until each selected workload passes its declared correctness profile and exact-output gate.
