# Valid Fixtures

Status: **Active** (last updated: 2026-08-15)

The folder name means the document must be accepted by a processor that implements the fixture's declared profile. `core` means XML 1.0 well-formedness. `namespaces` adds Namespaces in XML constraints. `dtd` means the document also satisfies its DTD validity constraints.

The exact processor expectations live in `../manifest.tsv`. A parser that intentionally lacks a feature is recorded as unsupported-feature, not silently counted as correct.
