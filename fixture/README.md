# XML Fixtures

Status: **Active** (last updated: 2026-08-23)

`fixture/` is the checked-in parser validation corpus. It is excluded from the Zig package so package tests remain self-contained. Package tests keep only byte-sensitive inputs under `tests/data/`; readable unit-test XML stays in its owning test.

`manifest.tsv` is the validation oracle. Each row states the expected classification and required processor features. Positive files combine compatible accepted behavior where one complete parse can exercise it. Negative files isolate one rejection because parsing stops at the first fatal error. Encoding files remain separate when byte order, declarations, malformed sequences, or line endings are the behavior under test. DTD and entity companions stay beside the document that resolves them.

`valid/` contains accepted core XML, encoding, namespace, DTD, and XML 1.1 cases. `invalid/` separates not-well-formed XML, encoding failures, namespace violations, DTD validity failures, and XML 1.1 violations. Local benchmark inputs and plans belong under ignored `bench/`; generated, downloaded, and measured data belongs under ignored `data/`. Neither is part of this validation corpus.

Run `make -C ref check-byte-fixtures` after changing byte-sensitive fixtures. After building the adapters, run `make -C ref check-corpus` to check the manifest against the parser lanes.
