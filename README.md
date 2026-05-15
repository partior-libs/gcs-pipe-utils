# gcs-pipe-utils
> Collection of reusable composite actions for general CICD controller pipeline operations.

## Overview

`gcs-pipe-utils` is a library of small, focused composite GitHub Actions used across Partior's CI/CD pipelines. Each sub-action lives under the `actions/` directory and is invoked individually. The most critical sub-action is `generic-runner-selection`, used by every pipeline to select the appropriate GitHub Actions runner pool.

## Usage

Reference any sub-action directly by its path:

```yaml
- name: Select runner pool
  id: runner-select
  uses: partior-libs/gcs-pipe-utils/actions/generic-runner-selection@partior-stable
  with:
    runner: self-hosted
    runner-cloud-provider: aws
    runner-env: prod
```

Then consume the output:

```yaml
jobs:
  build:
    needs: setup
    runs-on: ${{ fromJson(needs.setup.outputs.runners-pool) }}
```

## Sub-Actions

### `generic-runner-selection`

Detects and returns the appropriate runner pool as a JSON array.

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `runner` | Yes | — | Runner label (e.g., `self-hosted`) |
| `runner-cloud-provider` | No | — | Cloud provider tag (e.g., `aws`, `azure`) |
| `runner-env` | No | — | Environment tag (e.g., `prod`, `dev`) |
| `old-runner-label` | No | — | Legacy runner label for backward compatibility |
| `runner-limit` | No | — | Maximum number of runners to select |

**Outputs:**

| Output | Description |
|--------|-------------|
| `runners-pool` | JSON array of runner labels for use in `runs-on` |

### `generic-check-if-artifact-already-promoted`

Checks whether an artifact has already been promoted to a target repository, preventing duplicate promotions.

### `generic-check-properties-if-artifact-can-promote`

Validates artifact properties to determine if promotion criteria are met.

### `generic-convert-yaml-list-to-json-array`

Converts a YAML-formatted list into a JSON array string suitable for GitHub Actions matrix or other JSON consumers.

### `generic-convert-yaml-to-prop`

Converts a YAML file or section into Java `.properties` key=value format.

### `generic-create-pr`

Creates a pull request programmatically, with configurable title, body, base, and head branches.

### `generic-get-github-members` / `generic-get-github-members-by-graphql`

Retrieves GitHub organization members via REST API or GraphQL respectively.

### `generic-get-seq-from-uploaded-seqs`

Retrieves a specific sequence value from previously uploaded sequence artifacts.

### `generic-get-yaml-list-count-in-json-sequence`

Counts entries in a YAML list that has been serialized as a JSON sequence.

### `generic-git-tag`

Creates and pushes a Git tag with configurable tag name and message.

### `generic-init-std-promotion-variables`

Initializes the standard set of environment variables used by the promotion workflow.

### `generic-merge-release-pr`

Merges a release pull request after all checks pass.

### `generic-override-prop-conf` / `generic-override-yaml-conf`

Overrides values in a `.properties` file or YAML configuration file respectively.

### `generic-promote-version`

Promotes a versioned artifact from a dev/RC repository to a release repository.

### `generic-store-version-as-config-in-git` / `generic-store-version-as-list-config-in-git`

Persists a version string (or list of versions) back to a Git-based configuration file and commits it.

### `generic-update-release-definition`

Updates a release definition file with new artifact version information.

### `generic-yaml-merge`

Deep-merges two YAML files, with configurable override behavior.

### `platform-cd-utils`

Platform-level continuous delivery utilities for environment promotion and deployment tracking.

### Smart Contract (`smc-*`) Actions

| Sub-action | Description |
|-----------|-------------|
| `smc-backup-build-folder` | Archives the smart contract build output |
| `smc-consolidate-addresses-for-pctl` | Merges deployed contract addresses for Pctl tooling |
| `smc-generate-truffle-js` | Renders a `truffle-config.js` from template and environment variables |
| `smc-initial-setup-prep` | Prepares the workspace for a smart contract CI run |
| `smc-lookup-address` | Looks up a deployed contract address by name and network |
| `smc-store-all-addresses-to-git` | Commits all deployed contract addresses to the config Git repo |
| `smc-store-selection-addresses-to-git` | Commits a filtered subset of contract addresses to Git |

## Full Pipeline Example

```yaml
jobs:
  setup:
    runs-on: ubuntu-latest
    outputs:
      runners-pool: ${{ steps.runner-select.outputs.runners-pool }}
    steps:
      - name: Select runner
        id: runner-select
        uses: partior-libs/gcs-pipe-utils/actions/generic-runner-selection@partior-stable
        with:
          runner: self-hosted
          runner-cloud-provider: aws
          runner-env: prod

  build:
    needs: setup
    runs-on: ${{ fromJson(needs.setup.outputs.runners-pool) }}
    steps:
      - uses: actions/checkout@v4
      # ... build steps
```

## Prerequisites

- GitHub Actions runner with network access to target AWS/Azure environments (for cloud-specific runner selection).
- Appropriate GitHub token scopes for actions that create PRs or push tags (`contents: write`, `pull-requests: write`).

## Contributing

Follow the conventional commit format:

```
git commit -m "<TICKET_NUMBER> <COMMIT_MESSAGE>"
```

Example: `git commit -m "PLAT-123 Add support for azure runner pool selection"`

Target branch for changes: `partior-stable`

## License

See [LICENSE.md](LICENSE.md)
