# Invalid Fixtures

Status: **Active** (last updated: 2026-08-15)

This folder separates three kinds of negative test. `not_well_formed` must be rejected by every conforming processor for the required syntax. `namespaces` must be rejected by namespace-aware processors. `dtd` remains well-formed and must be rejected only by validating processors.

Unsupported-feature and out-of-profile pairs are recorded but not executed. This keeps deliberately narrow tokenizers and permissive subset parsers from being exposed to inputs outside their documented contract. Direct exploratory probes must run under the same process limits as the audit runner.
