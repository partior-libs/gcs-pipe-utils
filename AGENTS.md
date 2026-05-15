# AGENTS.md — gcs-pipe-utils

## Purpose

`gcs-pipe-utils` is a collection of reusable GitHub composite actions used across every Partior CI/CD pipeline. Each sub-action is self-contained under `actions/<name>/action.yml`. The most critical sub-action is `generic-runner-selection`, which every pipeline calls to obtain the correct runner pool before any work begins.

## Repository Map

```
gcs-pipe-utils/
├── actions/
│   ├── generic-runner-selection/        # ★ Used by ALL pipelines — select runner pool
│   ├── generic-check-if-artifact-already-promoted/
│   ├── generic-check-properties-if-artifact-can-promote/
│   ├── generic-convert-yaml-list-to-json-array/
│   ├── generic-convert-yaml-to-prop/
│   ├── generic-create-pr/
│   ├── generic-get-github-members/
│   ├── generic-get-github-members-by-graphql/
│   ├── generic-get-seq-from-uploaded-seqs/
│   ├── generic-get-yaml-list-count-in-json-sequence/
│   ├── generic-git-tag/
│   ├── generic-init-std-promotion-variables/
│   ├── generic-merge-release-pr/
│   ├── generic-override-prop-conf/
│   ├── generic-override-yaml-conf/
│   ├── generic-promote-version/
│   ├── generic-store-version-as-config-in-git/
│   ├── generic-store-version-as-list-config-in-git/
│   ├── generic-update-release-definition/
│   ├── generic-yaml-merge/
│   ├── platform-cd-utils/
│   ├── smc-backup-build-folder/
│   ├── smc-consolidate-addresses-for-pctl/
│   ├── smc-generate-truffle-js/
│   ├── smc-initial-setup-prep/
│   ├── smc-lookup-address/
│   ├── smc-store-all-addresses-to-git/
│   └── smc-store-selection-addresses-to-git/
├── scripts/                             # Shared shell scripts used by sub-actions
├── unit-test-config/                    # Unit test YAML fixtures
├── test.yaml                            # Top-level test workflow
└── README.md
```

Each sub-action has its own `action.yml` with `runs: composite`.

## Tech Stack

- **GitHub Actions** — Composite action runner (`runs: composite`)
- **Shell (bash)** — Primary scripting language for all action steps
- **yq** — YAML query and transformation (assumed available on runner)
- **GitHub API / GraphQL** — Used by `generic-get-github-members*` and PR/tag actions
- **JFrog Artifactory API** — Used by promotion-related actions

## Architecture Patterns

- **Sub-action library pattern**: Each action is a standalone composable unit in `actions/<name>/`. Callers reference the specific path: `uses: partior-libs/gcs-pipe-utils/actions/<name>@partior-stable`.
- **No top-level action**: There is no root `action.yml`. The repo is purely a collection namespace.
- **Shell-heavy**: Business logic lives in bash scripts, either inline in `action.yml` or in shared `scripts/`.
- **Output passing via `$GITHUB_OUTPUT`**: All outputs use the modern `echo "key=value" >> $GITHUB_OUTPUT` pattern.

## Development Commands

```bash
# Validate all action.yml files are well-formed YAML
for f in actions/*/action.yml; do yq '.' "$f" > /dev/null && echo "OK: $f" || echo "FAIL: $f"; done

# Run unit tests
# (Refer to test.yaml and unit-test-config/ for test scenarios)
cat test.yaml

# List all sub-action names
ls actions/
```

## Environment Setup

No local environment is strictly required; actions run in GitHub-hosted or self-hosted runners. For local validation:

```bash
# Install yq (used by many scripts)
brew install yq        # macOS
apt-get install -y yq  # Ubuntu

# Install GitHub CLI for API-touching actions
brew install gh
gh auth login
```

## Coding Conventions

- Sub-action names follow the pattern: `generic-<verb>-<noun>` or `smc-<verb>-<noun>`.
- Each sub-action directory contains exactly one `action.yml`.
- Shell scripts in `scripts/` use lowercase snake_case filenames with `.sh` extension.
- All action inputs/outputs must have `description` fields.
- Use `set -euo pipefail` at the top of all shell scripts.
- Prefer `>>  $GITHUB_OUTPUT` over `::set-output` (deprecated).

## Testing

- Unit test fixtures live in `unit-test-config/`.
- Integration tests are run via `test.yaml` as a GitHub Actions workflow.
- To add a test: add a scenario to `test.yaml` referencing the sub-action under `actions/`.
- There is no local test runner; tests must be triggered via GitHub Actions.

## Key Abstractions

| Abstraction | Location | Purpose |
|-------------|----------|---------|
| `generic-runner-selection` | `actions/generic-runner-selection/` | Returns `runners-pool` JSON; used as `runs-on` input |
| `generic-yaml-merge` | `actions/generic-yaml-merge/` | Deep merges two YAML files for config composition |
| `generic-promote-version` | `actions/generic-promote-version/` | Orchestrates Artifactory artifact promotion |
| `smc-*` family | `actions/smc-*/` | Smart contract specific build/deploy helpers |

## Agentic Task Guidance

✅ **Safe to add** a new sub-action by creating `actions/<new-name>/action.yml` with `runs: composite`.  
✅ **Safe to modify** an existing sub-action's shell steps — test via `test.yaml`.  
✅ **Safe to add** new scripts to `scripts/` and reference them from an `action.yml`.  
⚠️ **Be careful** when changing `generic-runner-selection` inputs/outputs — ALL pipelines depend on it; breaking changes affect the entire org.  
⚠️ **Be careful** renaming or removing any existing sub-action — callers reference by path and will break silently at runtime.  
❌ **Do not** add a root-level `action.yml` — this repo is a collection, not a single action.  
❌ **Do not** merge to `partior-stable` without running `test.yaml` successfully.  
❌ **Do not** use `::set-output` — use `$GITHUB_OUTPUT` instead.

## External Dependencies

- `yq` >= v4 — available on runner (install via `gcs-setup-yq`)
- `gh` CLI — for GraphQL and PR operations
- JFrog Artifactory — for promotion and version query actions
- GitHub REST API / GraphQL API — for member, PR, and tag operations

## Common Pitfalls

- **`runs-on` misuse**: `generic-runner-selection` output must be wrapped in `fromJson()` when used in `runs-on`. Example: `runs-on: ${{ fromJson(needs.setup.outputs.runners-pool) }}`.
- **Artifact not downloaded**: Cross-job consumers of uploaded artifacts must include `actions/download-artifact@v4` before sourcing.
- **yq not installed**: Several scripts call `yq` — ensure `gcs-setup-yq` runs before any `generic-*` action that transforms YAML.
- **API rate limits**: `generic-get-github-members-by-graphql` may hit GraphQL rate limits for large organizations — prefer the REST variant for small queries.
- **Tag conflicts**: `generic-git-tag` will fail if the tag already exists and force-push is not enabled.
