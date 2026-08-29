# XML Fixtures

Status: **Active** (last updated: 2026-08-28)

`fixture/` contains XML files used to check parser behavior. These files are tracked in the repository but are not included in the Zig package.

`manifest.tsv` lists each test file, its expected XML classification, and the parser features needed to check it. Accepted files can cover several related rules at once. Rejected files usually cover one error because parsing stops at the first fatal error.

The manifest entry defines the expected result. One file may serve more than one entry when the same bytes have different results under different parser modes.

- `valid/` contains files whose main cases are accepted core XML, encoding, namespace, DTD, and XML 1.1 inputs.
- `invalid/` contains files whose main cases are malformed XML, encoding errors, namespace errors, DTD validation errors, or XML 1.1 errors.
- DTD and entity files stay beside the XML document that refers to them.
- Byte-sensitive package tests stay under `tests/data/`. Readable unit-test XML stays in the test source.

Benchmark files do not belong here. Local benchmark plans and small inputs live under ignored `bench/`. Generated files, downloads, and results live under ignored `data/`.

After changing byte-sensitive fixtures, run:

```sh
make -C ref check-byte-fixtures
```

After building the parser adapters, check the complete manifest with:

```sh
make -C ref check-corpus
```
