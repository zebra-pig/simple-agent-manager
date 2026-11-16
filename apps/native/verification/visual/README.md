# Manual visual fixtures

These tools render production views with sample data. They are not automated
visual tests: no approved baseline comparison runs. Successful rendering only
means a bitmap was produced. Do not report that as a layout regression passing.

Render output belongs in ignored `.tmp/` or run artifacts. The behavior formerly
embedded in the chart renderer now lives in `ios/tests/behavior/resource-metrics.swift`.
Composer layout/actions and error presentation have real simulator tests; use
`bash apps/native/scripts/test.sh apple-ui <output> composer` or `errors`.

The remaining Swift render entry points compile with the production sources named
by their imports/types (exclude the shipping SAMApp.swift). Steering's shell
runner requires generated Apple bindings and runs an offline API. It is a manual
capture utility, not part of CI's test count. See [TESTING.md](../../TESTING.md).
