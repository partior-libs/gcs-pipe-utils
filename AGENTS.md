# AGENTS.md — gcs-pipe-utils

Guidance for AI coding agents, automated tooling, and LLM-based assistants working in this repository.

---

## Repository Purpose

`gcs-pipe-utils` is a library of **28 composite actions** (and one JavaScript action) providing reusable CI/CD pipeline utilities. It is consumed by `partior-libs/controller-generic-pipelines` and other Partior pipeline controllers.

Reference pattern:
```
partior-libs/gcs-pipe-utils/actions/<action-name>@partior-stable
```

---

## Repository Map

```
gcs-pipe-utils/
├── actions/                        # One directory per action
│   ├── generic-*/                  # Generic CI/CD utilities (composite)
│   ├── platform-cd-utils/          # Platform CD utilities (composite)
│   ├── smc-*/                      # Smart contract utilities (composite, except smc-lookup-address)
│   └── smc-lookup-address/         # JAVASCRIPT ACTION — different build process
│       ├── index.js
│       ├── package.json
│       └── dist/                   # Built output — regenerate with npm run build
├── scripts/                        # Shell scripts called by composite actions
│   ├── common-libs.sh              # Shared bash functions — sourced by all scripts
│   ├── generic-*.sh
│   ├── smc-*.sh
│   ├── update-release-definition.sh
│   └── python/
│       ├── github-app-token/       # GitHub App JWT token generator (Python)
│       └── itsm-cd-utils/
│           └── fsctl.py            # FreshService CD utilities
└── unit-test-config/               # Sample configs for unit test workflows
    ├── goquorum/
    ├── smc/
    └── deploy/
```

---

## Action Categories

### Category 1 — Generic CI/CD Utilities

Actions prefixed `generic-` handle general pipeline concerns independent of blockchain or smart contracts. They orchestrate common tasks such as git operations, YAML/properties manipulation, artifact promotion, PR management, and matrix job preparation.

**Actions that require JFrog Artifactory credentials:**
- `generic-check-if-artifact-already-promoted` — queries Artifactory for artifact promotion status
- `generic-check-properties-if-artifact-can-promote` — reads Artifactory artifact properties
- `generic-promote-version` — promotes artifact from one Artifactory repo to another

These actions expect Artifactory credentials via environment variables set by `jfrog/setup-jfrog-cli` or directly as inputs. Check each `action.yml` for the specific input names.

**Actions that require a GitHub PAT:**
- `generic-git-tag` — pushes a tag to a target repository
- `generic-create-pr` — creates PRs via GitHub API
- `generic-merge-release-pr` — merges release PRs
- `generic-store-version-as-config-in-git` — commits version strings to Git
- `generic-store-version-as-list-config-in-git` — commits version list entries to Git
- `generic-update-release-definition` — updates `release-definition.yaml` and commits

These actions use a `pat-token` input (or similar) — always pass from secrets.

### Category 2 — SMC (Smart Contract) Utilities

Actions prefixed `smc-` manage the lifecycle of deployed Ethereum smart contracts: address storage, build archiving, Truffle configuration generation, and PCTL integration.

**Special: `smc-lookup-address` is a JavaScript action**, not a composite shell action. It runs on Node.js 20 and must be compiled before changes take effect:

```bash
cd actions/smc-lookup-address
npm install
npm run build   # produces dist/index.js
```

Never edit `dist/index.js` directly — it is generated. Edit `index.js` (the source) instead.

---

## Scripts Directory

Each composite action in `actions/` delegates its core logic to a corresponding shell script in `scripts/`. The naming convention is consistent:

| Action | Script |
|---|---|
| `generic-convert-yaml-list-to-json-array` | `scripts/generic-convert-yaml-list-to-json-array.sh` |
| `generic-convert-yaml-to-prop` | `scripts/generic-convert-yaml-to-prop.sh` |
| `generic-create-pr` | `scripts/generic-create-pr.sh` |
| `generic-get-github-members` | `scripts/generic-get-github-members.sh` |
| `generic-get-github-members-by-graphql` | `scripts/generic-get-github-members-by-graphql.sh` |
| `generic-get-yaml-list-count-in-json-sequence` | `scripts/generic-get-yaml-list-count-in-json-sequence.sh` |
| `generic-git-tag` | `scripts/generic-git-tag.sh` |
| `generic-init-std-promotion-variables` | `scripts/generic-init-promotion-vars-get-*.sh` (two scripts) |
| `generic-override-prop-conf` | `scripts/generic-override-prop-conf.sh` |
| `generic-override-yaml-conf` | `scripts/generic-override-yaml-conf.sh` |
| `generic-store-version-as-config-in-git` | `scripts/generic-store-version-as-config-in-git.sh` |
| `generic-store-version-as-list-config-in-git` | `scripts/generic-store-version-as-list-config-in-git.sh` |
| `generic-yaml-merge` | `scripts/generic-yaml-merge.sh` |
| `generic-update-release-definition` | `scripts/update-release-definition.sh` |
| `smc-backup-build-folder` | `scripts/smc-backup-build-folder.sh` |
| `smc-consolidate-addresses-for-pctl` | `scripts/smc-consolidate-addresses-for-pctl.sh` |
| `smc-generate-truffle-js` | `scripts/smc-generate-truffle.sh` |
| `smc-initial-setup-prep` | `scripts/smc-initial-setup-prep.sh` |
| `smc-store-all-addresses-to-git` | `scripts/smc-store-all-addresses-to-git.sh` |
| `smc-store-selection-addresses-to-git` | `scripts/smc-store-selection-addresses-to-git.sh` |

### `scripts/common-libs.sh`

Shared bash utility functions sourced by all scripts. When writing or modifying a script:
- Source it at the top: `source "$(dirname "$0")/common-libs.sh"`
- Use its helper functions rather than reimplementing common operations (logging, error handling, Artifactory API helpers).
- When adding a new reusable utility, add it to `common-libs.sh` rather than duplicating it across scripts.

### `scripts/python/github-app-token/`

Generates GitHub App JWT tokens for workflows that need to authenticate as a GitHub App (rather than a PAT). Contains a standalone Python application — do not modify unless updating the GitHub Apps authentication flow.

### `scripts/python/itsm-cd-utils/fsctl.py`

FreshService ITSM integration for CD workflows. Used by `platform-cd-utils`. Requires FreshService API credentials passed via environment variables.

---

## Agentic Guidance

### When adding a new generic action

1. Create `actions/<action-name>/action.yml` following the naming convention `generic-<verb>-<noun>`.
2. Create the corresponding shell script at `scripts/<action-name>.sh`.
3. Source `common-libs.sh` in the script.
4. Add a unit test workflow at `.github/workflows/unit-test-<action-name>.yml`.
5. Add a sample config to `unit-test-config/` if the test requires one.
6. Update `README.md` — add a row to the Generic utilities table and a usage example if instructive.
7. Update this `AGENTS.md` — add a row to the scripts table.

### When adding a new SMC action

Follow the same steps as a generic action, using the `smc-` prefix. If the action needs to read or write smart contract addresses, use the existing address file format (JSON `{ "<ContractKey>": "<address>" }`) for consistency with `smc-lookup-address`.

### When modifying `smc-lookup-address`

This is the **only JavaScript action** in the repository. Changes require:
```bash
cd actions/smc-lookup-address
# Edit index.js
npm install          # update dependencies if changed
npm run build        # regenerates dist/index.js
git add dist/index.js
```
The `action.yml` for this action uses `using: node20` and points to `dist/index.js`.

### When modifying a composite action's inputs

1. Update `inputs:` in `action.yml`.
2. Update the corresponding script to handle the new input (passed as an env var or argument).
3. Update `README.md` with any new inputs.
4. Update unit tests.

### When actions need Artifactory

Actions that interact with Artifactory expect one of:
- The caller to run `jfrog/setup-jfrog-cli@v4` before invoking the action, **or**
- An explicit `jfrog-token` input that triggers setup within the action.

Check the specific `action.yml` for which pattern it uses. Do not assume both patterns are available for every action.

### Common Pitfalls

- **Do not use `GITHUB_TOKEN`** for cross-repository operations (tagging, PR creation) — these require a PAT with `repo` scope.
- **Do not edit `dist/`** in `smc-lookup-address` directly.
- **Do not inline large scripts** in `action.yml` YAML steps — keep logic in `scripts/` for testability.
- **`common-libs.sh` must be checked out** on the runner before any script that sources it. Composite actions handle this via their checkout step.
- **Unit test workflows** (`unit-test-*.yml`) use configurations from `unit-test-config/` — if you change a script's expected config format, update `unit-test-config/` accordingly.

---

## Unit Testing

There are 24+ unit test workflows in `.github/workflows/unit-test-*.yml`, each testing a specific action or script. They use sample configs from `unit-test-config/`.

To run a unit test locally (conceptually — they are GitHub Actions workflows):
1. Review the workflow YAML to understand the test inputs.
2. Run the corresponding shell script directly with the same inputs.
3. Validate the expected outputs.

---

## Credential Summary

| Credential Type | Actions that need it | Input name (typical) |
|---|---|---|
| GitHub PAT (`repo` scope) | git-tag, create-pr, merge-release-pr, store-version-*, update-release-definition | `pat-token` |
| JFrog Artifactory token | check-if-artifact-promoted, check-properties-can-promote, promote-version | `jfrog-token` or via JFrog CLI env |
| GitHub App credentials | platform-cd-utils (via `scripts/python/github-app-token/`) | per action |
| FreshService API key | platform-cd-utils (via `fsctl.py`) | env var |
