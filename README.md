# gcs-pipe-utils

A library of **28 GitHub Composite Actions** (and one JavaScript action) providing reusable CI/CD pipeline utilities for artifact promotion, configuration management, version tracking, smart contract address management, and more.

Used by [`partior-libs/controller-generic-pipelines`](https://github.com/partior-libs/controller-generic-pipelines) and other pipeline controllers across the Partior platform.

## Table of Contents

- [Reference Pattern](#reference-pattern)
- [Prerequisites](#prerequisites)
- [Actions — Generic CI/CD Utilities](#actions--generic-cicd-utilities)
- [Actions — SMC (Smart Contract) Utilities](#actions--smc-smart-contract-utilities)
- [Usage Examples](#usage-examples)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

---

## Reference Pattern

All composite actions are referenced using:

```
partior-libs/gcs-pipe-utils/actions/<action-name>@partior-stable
```

Replace `partior-stable` with a specific commit SHA to pin the version for production workflows.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **GitHub PAT** | Several actions (git-tag, create-pr, store-version) require a PAT with `repo` scope |
| **JFrog Artifactory token** | Actions that interact with Artifactory require a token with read/write permissions |
| **Python 3** | Required for GitHub App token scripts (`scripts/python/`) |
| **Node.js 20** | Required for `smc-lookup-address` (JavaScript action) |
| **`yq` / `jq`** | Available on GitHub-hosted runners; required by YAML/JSON conversion actions |

---

## Actions — Generic CI/CD Utilities

| Action | Description |
|---|---|
| [`generic-check-if-artifact-already-promoted`](#generic-check-if-artifact-already-promoted) | Query JFrog Artifactory to determine whether an artifact has already been promoted to the release repository |
| [`generic-check-properties-if-artifact-can-promote`](#generic-check-properties-if-artifact-can-promote) | Read artifact properties from Artifactory and evaluate whether promotion is permitted |
| [`generic-convert-yaml-list-to-json-array`](#generic-convert-yaml-list-to-json-array) | Extract a YAML sequence and convert it to a JSON array suitable for GitHub Actions matrix jobs |
| [`generic-convert-yaml-to-prop`](#generic-convert-yaml-to-prop) | Convert a YAML configuration file to Java `.properties` key=value format |
| [`generic-create-pr`](#generic-create-pr) | Create a pull request between two branches, or return an existing PR number if one already exists |
| [`generic-get-github-members`](#generic-get-github-members) | Retrieve GitHub organisation member details via the REST API |
| [`generic-get-github-members-by-graphql`](#generic-get-github-members-by-graphql) | Retrieve GitHub organisation member details via the GraphQL API |
| [`generic-get-seq-from-uploaded-seqs`](#generic-get-seq-from-uploaded-seqs) | Download an uploaded sequence artifact and generate a list for matrix job use |
| [`generic-get-yaml-list-count-in-json-sequence`](#generic-get-yaml-list-count-in-json-sequence) | Count items in a YAML list and return the result as a numeric JSON sequence for matrix jobs |
| [`generic-git-tag`](#generic-git-tag) | Create or update a git tag on a target repository |
| [`generic-init-std-promotion-variables`](#generic-init-std-promotion-variables) | Initialise and inject standard promotion pipeline variables into the workflow environment |
| [`generic-merge-release-pr`](#generic-merge-release-pr) | Merge a release pull request as part of the promotion stage |
| [`generic-override-prop-conf`](#generic-override-prop-conf) | Override one or more values in a `.properties` configuration file |
| [`generic-override-yaml-conf`](#generic-override-yaml-conf) | Override one or more values in a YAML configuration file |
| [`generic-promote-version`](#generic-promote-version) | Promote an artifact version in JFrog Artifactory from one repository to another |
| [`generic-runner-selection`](#generic-runner-selection) | Auto-detect the appropriate runner pool and return it as a JSON string for `runs-on` |
| [`generic-store-version-as-config-in-git`](#generic-store-version-as-config-in-git) | Store a version string as a single config entry and commit it to Git |
| [`generic-store-version-as-list-config-in-git`](#generic-store-version-as-list-config-in-git) | Append a version string as a list config entry and commit it to Git |
| [`generic-update-release-definition`](#generic-update-release-definition) | Update or append a component version entry in `release-definition.yaml` |
| [`generic-yaml-merge`](#generic-yaml-merge) | Deep-merge two YAML files according to a provided merge configuration |
| [`platform-cd-utils`](#platform-cd-utils) | Composite of platform-level CD utility steps used across deployment pipelines |

---

## Actions — SMC (Smart Contract) Utilities

| Action | Description |
|---|---|
| [`smc-backup-build-folder`](#smc-backup-build-folder) | Archive the SMC build output folder to Artifactory and record the version in the build manifest |
| [`smc-consolidate-addresses-for-pctl`](#smc-consolidate-addresses-for-pctl) | Consolidate mapped smart contract addresses into the format required by PCTL |
| [`smc-generate-truffle-js`](#smc-generate-truffle-js) | Generate a `truffle.config.js` file from a YAML network configuration |
| [`smc-initial-setup-prep`](#smc-initial-setup-prep) | Read environment configuration and retrieve the SMC initial setup sequence list |
| [`smc-lookup-address`](#smc-lookup-address) | **JavaScript action.** Look up a deployed smart contract address by contract key |
| [`smc-store-all-addresses-to-git`](#smc-store-all-addresses-to-git) | Retrieve all deployed smart contract addresses and commit them to Git |
| [`smc-store-selection-addresses-to-git`](#smc-store-selection-addresses-to-git) | Retrieve a selected subset of key-value contract addresses and commit them to Git |

---

## Usage Examples

### `generic-git-tag` — Tag a repository

```yaml
- name: Tag release
  uses: partior-libs/gcs-pipe-utils/actions/generic-git-tag@partior-stable
  with:
    target-repo: my-org/my-service
    target-repo-ref: main
    artifact-version: '25.1.4'
    pat-token: ${{ secrets.GH_PAT }}
```

### `generic-convert-yaml-list-to-json-array` — Build a matrix from YAML

```yaml
- name: Get deploy targets
  id: get-targets
  uses: partior-libs/gcs-pipe-utils/actions/generic-convert-yaml-list-to-json-array@partior-stable
  with:
    yaml-file: ./deploy-config.yaml
    yaml-path-to-config: environments.targets
    exclusion-name-list: 'staging'

- name: Deploy to all targets
  strategy:
    matrix:
      target: ${{ fromJson(steps.get-targets.outputs.found-list) }}
  uses: ./.github/workflows/deploy.yml
  with:
    environment: ${{ matrix.target }}
```

### `generic-runner-selection` — Dynamic runner pool selection

```yaml
- name: Select runner
  id: select-runner
  uses: partior-libs/gcs-pipe-utils/actions/generic-runner-selection@partior-stable
  with:
    runner-cloud-provider: gcp
    runner-env: devnet03
    runner-limit: standard

- name: Use selected runner
  runs-on: ${{ fromJson(steps.select-runner.outputs.runner-label) }}
  steps:
    - run: echo "Running on selected runner"
```

### `smc-lookup-address` — Look up a contract address

```yaml
- name: Get contract address
  id: lookup
  uses: partior-libs/gcs-pipe-utils/actions/smc-lookup-address@partior-stable
  with:
    contract-key: SettlementManager
    address-file: ./deployments/addresses.json

- name: Use address
  run: echo "Contract deployed at ${{ steps.lookup.outputs.contract-address }}"
```

---

## Project Structure

```
gcs-pipe-utils/
├── actions/
│   ├── generic-check-if-artifact-already-promoted/
│   │   └── action.yml
│   ├── generic-check-properties-if-artifact-can-promote/
│   │   └── action.yml
│   ├── generic-convert-yaml-list-to-json-array/
│   │   └── action.yml
│   ├── generic-convert-yaml-to-prop/
│   │   └── action.yml
│   ├── generic-create-pr/
│   │   └── action.yml
│   ├── generic-get-github-members/
│   │   └── action.yml
│   ├── generic-get-github-members-by-graphql/
│   │   └── action.yml
│   ├── generic-get-seq-from-uploaded-seqs/
│   │   └── action.yml
│   ├── generic-get-yaml-list-count-in-json-sequence/
│   │   └── action.yml
│   ├── generic-git-tag/
│   │   └── action.yml
│   ├── generic-init-std-promotion-variables/
│   │   └── action.yml
│   ├── generic-merge-release-pr/
│   │   └── action.yml
│   ├── generic-override-prop-conf/
│   │   └── action.yml
│   ├── generic-override-yaml-conf/
│   │   └── action.yml
│   ├── generic-promote-version/
│   │   └── action.yml
│   ├── generic-runner-selection/
│   │   └── action.yml
│   ├── generic-store-version-as-config-in-git/
│   │   └── action.yml
│   ├── generic-store-version-as-list-config-in-git/
│   │   └── action.yml
│   ├── generic-update-release-definition/
│   │   └── action.yml
│   ├── generic-yaml-merge/
│   │   └── action.yml
│   ├── platform-cd-utils/
│   │   └── action.yml
│   ├── smc-backup-build-folder/
│   │   └── action.yml
│   ├── smc-consolidate-addresses-for-pctl/
│   │   └── action.yml
│   ├── smc-generate-truffle-js/
│   │   └── action.yml
│   ├── smc-initial-setup-prep/
│   │   └── action.yml
│   ├── smc-lookup-address/
│   │   ├── action.yml           # JavaScript action (using: node20)
│   │   ├── index.js
│   │   ├── package.json
│   │   ├── package-lock.json
│   │   └── dist/
│   ├── smc-store-all-addresses-to-git/
│   │   └── action.yml
│   └── smc-store-selection-addresses-to-git/
│       └── action.yml
├── scripts/
│   ├── common-libs.sh                          # Shared bash utility functions
│   ├── generic-convert-yaml-list-to-json-array.sh
│   ├── generic-convert-yaml-to-prop.sh
│   ├── generic-create-pr.sh
│   ├── generic-curl-get-artifact-meta.sh
│   ├── generic-get-github-members.sh
│   ├── generic-get-github-members-by-graphql.sh
│   ├── generic-get-yaml-list-count-in-json-sequence.sh
│   ├── generic-git-tag.sh
│   ├── generic-init-promotion-vars-get-artifacts-details.sh
│   ├── generic-init-promotion-vars-get-store-git-details.sh
│   ├── generic-override-prop-conf.sh
│   ├── generic-override-yaml-conf.sh
│   ├── generic-store-version-as-config-in-git.sh
│   ├── generic-store-version-as-list-config-in-git.sh
│   ├── generic-validate-pr-status.sh
│   ├── generic-yaml-merge.sh
│   ├── smc-backup-build-folder.sh
│   ├── smc-consolidate-addresses-for-pctl.sh
│   ├── smc-generate-truffle.sh
│   ├── smc-initial-setup-prep.sh
│   ├── smc-store-all-addresses-to-git.sh
│   ├── smc-store-selection-addresses-to-git.sh
│   ├── update-release-definition.sh
│   └── python/
│       ├── github-app-token/                   # GitHub App JWT token generator
│       └── itsm-cd-utils/
│           └── fsctl.py                        # FreshService CD utilities
├── unit-test-config/                           # Sample configs for unit tests
│   ├── goquorum/
│   ├── smc/
│   └── deploy/
├── .github/
│   └── workflows/
│       └── unit-test-*.yml                     # 24+ unit test workflows
└── LICENSE.md
```

---

## Contributing

1. Fork the repository and create a feature branch.
2. For composite actions: edit the relevant `actions/<name>/action.yml` and the corresponding script in `scripts/`.
3. For `smc-lookup-address`: edit `actions/smc-lookup-address/index.js`, then run `npm run build` to regenerate `dist/`.
4. Add or update the corresponding unit test workflow in `.github/workflows/unit-test-<name>.yml`.
5. Include a sample config in `unit-test-config/` if your change requires one.
6. Open a pull request against `partior-stable`.

---

## License

See [LICENSE.md](LICENSE.md).

