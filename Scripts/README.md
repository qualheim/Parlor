# Scripts

Build, lint, and simulation helper scripts invoked by the `Makefile` (structure.md).

- `lint.sh` enforces forbidden imports/APIs, UI-framework imports inside the pure layer,
  dependency-direction violations, and unexpected entitlements.
- `generate-seed-pool.sh` writes a deterministic newline-delimited seed pool for `parlor-sim`; the
  Makefile's `test` and `test-long` targets generate the required 500/10,000 seed pools automatically.
- `check-coverage.sh` is the line-coverage gate (R-QA-7.1). `make test` and `make test-long` run it right
  after `swift test --enable-code-coverage`; it fails unless each scope has at least 90% line coverage:
  EngineCore, the GamesRules target as a whole, the Klondike rules, and the Crazy Eights rules including
  their AI tiers. Coverage is the union over every test bundle, with no file exclusions. Scopes and the
  default minimum are set at the top of the script.

To generate a small reproducible pool manually:

```sh
Scripts/generate-seed-pool.sh --count 10 --base 20240601 --output .build/parlor-sim-seeds.txt
```

To check coverage without the simulation stage (add `--verbose` for a per-file breakdown):

```sh
swift test --enable-code-coverage
Scripts/check-coverage.sh
```

