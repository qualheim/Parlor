# Makefile — Parlor build pipeline (R-BUILD-2).
#
# Every developer and CI workflow runs headless from a terminal so local and CI runs behave
# identically (R-BUILD-2 user story). The package layer (EngineCore, AIKit, GamesRules, GamesUI,
# TableKit, DesignSystem, Persistence, SimulationCLI) builds and tests with SwiftPM and needs only the
# Swift command line tools; the App bundle is produced from the XcodeGen-generated project and needs a
# full Xcode install for `make run`.
#
# Required targets (names fixed by tech.md; R-BUILD-2.1):
#   bootstrap  generate  build  test  test-long  lint  format  run  sim
#
# GRACEFUL DEGRADATION: this environment may have Swift command line tools only (no full Xcode, no
# XcodeGen, no standalone swift-format). Targets that need a missing tool print an actionable message
# and exit non-zero rather than failing obscurely; `bootstrap` installs what it can. Targets that only
# need SwiftPM (build/test/test-long/sim, and lint/format via the toolchain's `swift format`) work with
# command line tools alone.

# ---------------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------------

# App bundle metadata (mirrors project.yml).
APP_NAME          := Parlor
SCHEME            := Parlor
XCODEPROJ         := $(APP_NAME).xcodeproj
CONFIGURATION     ?= Debug
DERIVED_DATA      := .build/DerivedData

# parlor-sim game-count gates (R-QA-2.2). Wired here; enforced by the sim harness in task 8.1.
SIM_GAMES_FAST    ?= 500
SIM_GAMES_LONG    ?= 10000

# swift-format resolution (R-BUILD-4.1). Prefer a standalone `swift-format` binary; otherwise fall back
# to the `swift format` subcommand bundled with the Swift 6 toolchain. Empty if neither is available.
SWIFT_FORMAT_BIN  := $(shell command -v swift-format 2>/dev/null)
ifeq ($(SWIFT_FORMAT_BIN),)
  ifeq ($(shell swift format --version >/dev/null 2>&1 && echo yes),yes)
    SWIFT_FORMAT := swift format
  else
    SWIFT_FORMAT :=
  endif
else
  SWIFT_FORMAT := $(SWIFT_FORMAT_BIN)
endif

# Swift sources to format/lint (App shell + all packages). Excludes build products.
SWIFT_SOURCES     := App Packages Package.swift

.DEFAULT_GOAL := build

.PHONY: bootstrap generate build test test-long lint format run sim help \
        _require-xcodegen _require-xcode _check-swift-format

help: ## List the available targets.
	@echo "Parlor make targets:"
	@echo "  bootstrap   Install missing tools (Xcode CLT, XcodeGen, swift-format) then generate the project"
	@echo "  generate    Generate $(XCODEPROJ) from project.yml via XcodeGen"
	@echo "  build       Build all packages headless (swift build)"
	@echo "  test        Run the fast test sample headless (swift test)"
	@echo "  test-long   Run the full-volume suite ($(SIM_GAMES_LONG) games/game — task 8.1)"
	@echo "  lint        swift-format --check + architecture/entitlement checks (task 1.4)"
	@echo "  format      Format all Swift sources in place"
	@echo "  run         Build and launch the app with local (ad-hoc) signing (needs full Xcode)"
	@echo "  sim         Run the parlor-sim harness (swift run parlor-sim)"

# ---------------------------------------------------------------------------------------------------
# bootstrap — check for / install required tools, then generate the project (R-BUILD-2.2)
# ---------------------------------------------------------------------------------------------------

bootstrap: ## Install missing tools then generate the Xcode project.
	@echo "==> Bootstrapping Parlor toolchain"
	@# --- Xcode command line tools (R-BUILD-2.2) ---
	@if xcode-select -p >/dev/null 2>&1; then \
		echo "  [ok] Xcode command line tools: $$(xcode-select -p)"; \
	else \
		echo "  [..] Installing Xcode command line tools (a system dialog may appear)"; \
		xcode-select --install || true; \
		echo "  [!!] Re-run 'make bootstrap' after the command line tools finish installing."; \
	fi
	@# --- Homebrew (used to install XcodeGen / swift-format) ---
	@if ! command -v brew >/dev/null 2>&1; then \
		echo "  [!!] Homebrew not found. Install it from https://brew.sh, then re-run 'make bootstrap'."; \
		echo "       (XcodeGen and swift-format are installed via Homebrew.)"; \
	fi
	@# --- XcodeGen (R-BUILD-2.2) ---
	@if command -v xcodegen >/dev/null 2>&1; then \
		echo "  [ok] XcodeGen: $$(xcodegen --version 2>/dev/null | head -1)"; \
	elif command -v brew >/dev/null 2>&1; then \
		echo "  [..] Installing XcodeGen via Homebrew"; \
		brew install xcodegen; \
	else \
		echo "  [!!] XcodeGen missing and Homebrew unavailable — skipping (install: brew install xcodegen)."; \
	fi
	@# --- swift-format (R-BUILD-4.1; standalone binary preferred, toolchain 'swift format' is a fallback) ---
	@if command -v swift-format >/dev/null 2>&1; then \
		echo "  [ok] swift-format (standalone)"; \
	elif swift format --version >/dev/null 2>&1; then \
		echo "  [ok] swift-format (via toolchain 'swift format')"; \
	elif command -v brew >/dev/null 2>&1; then \
		echo "  [..] Installing swift-format via Homebrew"; \
		brew install swift-format; \
	else \
		echo "  [!!] swift-format missing and Homebrew unavailable — skipping (install: brew install swift-format)."; \
	fi
	@# --- Generate the project (R-BUILD-2.2) ---
	@if command -v xcodegen >/dev/null 2>&1; then \
		$(MAKE) generate; \
	else \
		echo "  [!!] Skipping project generation — XcodeGen is not installed."; \
	fi
	@echo "==> Bootstrap complete"

# ---------------------------------------------------------------------------------------------------
# generate — XcodeGen project generation (R-BUILD-1.3)
# ---------------------------------------------------------------------------------------------------

generate: _require-xcodegen ## Generate the Xcode project from project.yml.
	@echo "==> Generating $(XCODEPROJ) from project.yml"
	@xcodegen generate --spec project.yml

_require-xcodegen:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "error: XcodeGen is not installed."; \
		echo "       Install it with 'brew install xcodegen' or run 'make bootstrap'."; \
		exit 1; }

# ---------------------------------------------------------------------------------------------------
# build / test / test-long — headless SwiftPM (R-BUILD-2.4, R-BUILD-1.2)
# ---------------------------------------------------------------------------------------------------

build: ## Build all packages headless.
	@echo "==> swift build (all packages)"
	@swift build

test: ## Run the fast test sample headless (R-BUILD-2.4, R-QA-2).
	@echo "==> swift test"
	@swift test

# Full-volume suite (R-BUILD-2.4): parlor-sim runs $(SIM_GAMES_LONG) games/game. The harness and its
# PARLOR_SIM_GAMES gate are implemented in task 8.1; this target wires the entry point now so that work
# fills it in without touching the Makefile.
test-long: ## Run the full-volume suite (10,000 games/game — task 8.1).
	@echo "==> swift test (full suite) + parlor-sim x $(SIM_GAMES_LONG) games/game"
	@swift test
	@PARLOR_SIM_GAMES=$(SIM_GAMES_LONG) swift run parlor-sim || \
		echo "  [note] parlor-sim volume gate ($(SIM_GAMES_LONG) games) is completed in task 8.1."

# ---------------------------------------------------------------------------------------------------
# lint / format — swift-format + architecture checks (R-BUILD-4.1; full checks in task 1.4)
# ---------------------------------------------------------------------------------------------------

lint: _check-swift-format ## Check formatting + architecture/entitlement rules.
	@echo "==> Lint: swift-format check"
	@$(SWIFT_FORMAT) lint --strict --recursive $(SWIFT_SOURCES)
	@# The forbidden-import / UI-in-pure-layer / dependency-direction / entitlement checks
	@# (R-BUILD-4.2, R-BUILD-4.3, R-BUILD-4.4, R-BUILD-3.4) are added under Scripts/ in task 1.4 and
	@# invoked here:
	@if [ -x Scripts/lint.sh ]; then Scripts/lint.sh; else \
		echo "  [note] Architecture/entitlement lint scripts land in task 1.4 (Scripts/lint.sh)."; fi

format: _check-swift-format ## Format all Swift sources in place.
	@echo "==> Formatting Swift sources in place"
	@$(SWIFT_FORMAT) format --in-place --recursive $(SWIFT_SOURCES)

_check-swift-format:
	@if [ -z "$(SWIFT_FORMAT)" ]; then \
		echo "error: swift-format is not available."; \
		echo "       Install it with 'brew install swift-format' or use a Swift 6 toolchain"; \
		echo "       ('swift format'), or run 'make bootstrap'."; \
		exit 1; fi

# ---------------------------------------------------------------------------------------------------
# run — build and launch the app with local (ad-hoc) signing (R-BUILD-2.3)
# ---------------------------------------------------------------------------------------------------
#
# The App is a macOS .app bundle, so it is built through the XcodeGen-generated project with xcodebuild
# (a full Xcode install, not just the command line tools). Signing is ad-hoc ("-", set in project.yml)
# so no developer certificate is needed. Under a command-line-tools-only setup this target explains
# what to install rather than failing obscurely.

run: _require-xcode ## Build and launch the app (ad-hoc signed).
	@if [ ! -d "$(XCODEPROJ)" ]; then $(MAKE) generate; fi
	@echo "==> Building $(SCHEME) ($(CONFIGURATION)) with local (ad-hoc) signing"
	@xcodebuild \
		-project "$(XCODEPROJ)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
		build
	@echo "==> Launching $(APP_NAME)"
	@open "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app"

_require-xcode:
	@if ! xcodebuild -version >/dev/null 2>&1; then \
		echo "error: 'make run' builds the macOS app bundle and needs a full Xcode install."; \
		echo "       You appear to have the Swift command line tools only."; \
		echo "       Install Xcode, then run 'sudo xcode-select -s /Applications/Xcode.app'."; \
		echo "       (Headless 'make build' / 'make test' work with the command line tools alone.)"; \
		exit 1; fi

# ---------------------------------------------------------------------------------------------------
# sim — parlor-sim harness (R-QA-2; fleshed out in task 8.1)
# ---------------------------------------------------------------------------------------------------

sim: ## Run the parlor-sim harness.
	@echo "==> swift run parlor-sim"
	@swift run parlor-sim
