# z-xml

Status: **Active** (last updated: 2026-08-19)

`z-xml` is a compile-time-specialized streaming XML library and parser benchmark laboratory for Zig 0.16. Conformance data, matched workloads, and reproducible peer builds keep correctness and performance claims measurable.

The repository contains qualified raw-name and namespace-aware XML 1.0 readers for no-DTD and non-validating DTD input. The non-validating readers parse internal and external subsets, apply parameter and general parsed entities, normalize and default declared attributes, and expose DTD events under explicit declaration, grammar, comparison, recursion, expansion, and resolver limits. UTF-8, UTF-16LE, and UTF-16BE sources are built in. Other external-source encodings require a caller-supplied transcoder. External access requires a caller-owned resolver and grants no implicit filesystem or network authority. DTD validation, XML 1.1, and the owned tree are not implemented.

Build the library checks with the pinned compiler:

```sh
./zig-0.16.0/zig build test
./zig-0.16.0/zig build test -Doptimize=ReleaseFast
./zig-0.16.0/zig build layout -Doptimize=ReleaseFast
```

The reference laboratory in [`ref/`](ref/README.md), the checked-in valid and invalid corpus in [`fixture/`](fixture/README.md), and the measurement tooling qualify parser behavior. The standards boundary, evidence, reader and validation contracts, compact tree, performance targets, and architecture live in [`plan/design/`](plan/design/README.md).

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
