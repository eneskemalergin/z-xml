# XML Fixtures

Status: **Active** (last updated: 2026-08-23)

`fixture/` is the checked-in development corpus. It is excluded from the Zig package so package tests remain self-contained. Package tests keep only byte-sensitive inputs under `tests/data/`; readable unit-test XML stays in its owning test.

`manifest.tsv` is the corpus oracle. Each row states the expected classification, required processor features, and whether the file may seed a benchmark. Positive files combine compatible accepted behavior where one complete parse can exercise it. Negative files isolate one rejection because parsing stops at the first fatal error. Encoding files remain separate when byte order, declarations, malformed sequences, or line endings are the behavior under test. DTD and entity companions stay beside the document that resolves them.

`valid/` contains accepted core XML, encoding, namespace, DTD, and XML 1.1 cases. `invalid/` separates not-well-formed XML, encoding failures, namespace violations, DTD validity failures, and XML 1.1 violations. `benchmark/smoke/` contains tiny exact-output protocol inputs. The TSV files under `benchmark/plans/` describe generated workloads and their semantic oracles. Generated and downloaded corpora stay under ignored `data/` paths.

Run `make -C ref check-byte-fixtures check-shape-matrix` after changing fixtures. After building the adapters, run `make -C ref check-corpus` before measuring anything.
