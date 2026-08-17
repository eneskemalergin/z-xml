# z-xml

Status: **Active** (last updated: 2026-08-16)

`z-xml` is a benchmark-led effort to build a complete, lightweight, high-performance XML library for Zig 0.16. The target includes compile-time-specialized streaming readers, XML namespaces, UTF-8 and UTF-16, complete non-validating DTD behavior, optional DTD validation, XML 1.1 compatibility, and a compact owned DOM. Conformance data, matched workloads, and reproducible peer builds keep correctness and performance decisions measurable.

The repository now contains the compiled reader type factory, lifecycle, specialized event and diagnostic shapes, whole-slice and buffered-I/O adapters, push drain, layout probe, and the complete staged XML 1.0 UTF-8 no-DTD grammar. That grammar includes XML declarations, delayed document metadata, XML 1.0 Fifth Edition names, atomic normalized source attributes, semantic text and CDATA, numeric and predefined references, line-ending normalization, comments, processing instructions, legal prolog and epilog miscellaneous content, and an explicit unsupported DOCTYPE boundary. The reader validates malformed UTF-8 and forbidden XML characters across arbitrary caller chunks while retaining only active element, start-tag, decoder-suffix, delimiter, target, declaration, and fixed fragment state. This is feature-complete Stage 6 code, not a complete conformance, security, memory, or performance claim. Stage 7 qualification, namespaces, UTF-16, DTD behavior, validation, and the tree follow the gates in [`plan/ROADMAP.md`](plan/ROADMAP.md).

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
