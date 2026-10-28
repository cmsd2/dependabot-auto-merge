# dependabot-auto-merge

A reusable GitHub Actions workflow that arms GitHub auto-merge for low-risk
Dependabot PRs, so GitHub merges them once the repo's required checks pass. It
never merges by itself, and it only approves a PR if you opt in with
`approve: true`.

A PR is armed only if **all** hold:

- it was opened by `dependabot[bot]`, and `dependabot[bot]` triggered the run
- every updated dependency is a **minor or patch** bump (read from
  `dependabot/fetch-metadata`; majors and range-only changes are skipped)
- it changes only files matching `allowed-files` (globs; default `uv.lock pyproject.toml`)
- `required-check` is a **required status check** on the base branch, through
  classic branch protection **or** a ruleset (both are checked). Without this,
  auto-merge would merge immediately, so the workflow refuses.

Otherwise it logs a notice saying why and leaves the PR for a human. If the
workflow cannot read the PR's changed files or the branch's protection, it
treats that as a failed gate.

## Files

- `.github/workflows/dependabot-auto-merge.yml`: the reusable workflow (`on: workflow_call`).
- `.github/workflows/test.yml`: CI for this repo. Runs the tests, shellcheck and actionlint.
- `.github/dependabot.yml`: keeps this repo's own action pins current.
- `test/test_decision.sh`: runs the workflow's decision script against a stubbed `gh`.

## Use it

In the consuming repo, `.github/workflows/dependabot-auto-merge.yml`:

```yaml
name: Dependabot auto-merge
on: pull_request
permissions:
  contents: write
  pull-requests: write
jobs:
  auto-merge:
    if: github.actor == 'dependabot[bot]'
    uses: cmsd2/dependabot-auto-merge/.github/workflows/dependabot-auto-merge.yml@<full-sha> # v1.0.0
    with:
      required-check: test
```

Pin to a full commit SHA, not a branch or tag. Dependabot's `github-actions`
ecosystem can keep the pin current when this repo has tagged releases. The
`uses:` line names the owner and repo, so update it if this repo is renamed or
moved.

### Access from other repos

This repo is private. GitHub only lets other repos call its workflow when
Settings > Actions > General > Access is set to *Accessible from repositories
owned by the user 'cmsd2'*. Even then, only private repos owned by `cmsd2` can
call it. A public repo cannot use a workflow from a private one, so to use it
there, make this repo public or copy the workflow file.

## Before you add it to a repo (in this order)

1. Have a workflow that runs your tests on `pull_request`, whose job name is the
   `required-check` value, and which is **not path-filtered** (a filtered workflow
   never reports on other PRs, leaving a required check stuck on "Expected").
2. Enable "Allow auto-merge" in the repo settings.
3. Add the caller workflow above.
4. **Rebase open Dependabot PRs** (`@dependabot rebase`). Ones opened before
   step 1 have no test run and would stay blocked once the check is required.
5. Only then require the check on the default branch. Consider leaving
   "Require branches to be up to date" off: auto-merge doesn't update branches,
   so an armed PR that falls behind stalls.

Branch protection and rulesets on private repos need a paid plan (GitHub Pro or
above). On GitHub Free a private repo cannot require a check, so the workflow
always skips there.

## Inputs

| Input | Default | |
|---|---|---|
| `required-check` | (required) | Status check that must be required on the base branch |
| `allowed-files` | `uv.lock pyproject.toml` | Space-separated globs for the only files an auto-merged PR may change |
| `merge-method` | `squash` | `squash`, `merge` or `rebase`. Anything else fails the run |
| `approve` | `false` | Also approve the PR after every gate passes |
| `runner` | `ubuntu-latest` | Runner label. For a self-hosted runner group, change `runs-on` in the workflow to `group: ...` |

## Bot approval (`approve: true`)

For branches that require a review, an armed PR waits for an approval. With
`approve: true` the workflow supplies it: `gh pr review --approve` runs **after**
every gate has passed, as the last step, so a PR that fails any gate is never
approved. If the approval fails the PR stays armed and waits for a human.

Think before enabling it: a Dependabot PR can then merge with no human looking at
it, so the required check must really exercise the code. It needs *Allow GitHub
Actions to create and approve pull requests* turned on for the repo. Off by default.

## `allowed-files` patterns

Bash globs, space-separated. `*` matches any characters including `/`, and a
leading `**/` also matches the repo root, so `**/pom.xml` allows `pom.xml`,
`module-a/pom.xml` and `module-a/sub/pom.xml` but not `pom.xml.bak`. Patterns are
never expanded against the runner's files.

## Maven / Java

```yaml
    with:
      required-check: build        # your CI job name
      allowed-files: "**/pom.xml"
```

Things this workflow cannot see, to check per repo before relying on it:

- **Private registries.** If dependencies or parent POMs come from a private
  registry, `dependabot.yml` needs a `registries:` block and the credentials must
  be stored as **Dependabot secrets**. Workflows triggered by Dependabot PRs cannot
  read normal Actions secrets, so a build needing credentials fails on those PRs.
- **Version formats.** Versions that are not semver (`1.2.3.Final`, date-based)
  may come back from `fetch-metadata` without an update type. The workflow then
  skips the PR, which is safe, but check the hit rate on the first few PRs.
- **No lockfile.** A fix edits `pom.xml` (possibly version properties), and a
  vulnerable transitive dependency cannot be fixed by a bump alone.

## Workflows after the merge

The workflow arms auto-merge with the run's `GITHUB_TOKEN`, so GitHub records
the merge as made by `github-actions[bot]`. GitHub does not start new workflow
runs for events caused by `GITHUB_TOKEN`, so a workflow on `push` to the default
branch (a deploy, say) does not run for these merges. If you need it to, trigger
it another way, such as a schedule or `workflow_dispatch`.

## Tests

```bash
test/test_decision.sh
```

Needs `bash`, `jq` and `uv` (to read the workflow YAML). It extracts the
decision script from the workflow and runs it against a stubbed `gh` for 35
cases: update types, opt-in approval (never before the gates), exact and glob
file matching (including multi-module Maven layouts), required checks via
classic protection and rulesets, merge-method validation, and API errors
failing closed. The tests were mutation-checked against deliberate bugs:
removing `set -f`, ignoring rulesets, dropping the `**/` root rule, approving
before the gates, skipping merge-method validation, and reading the file list
in a way that ignores a failed `gh pr diff`.

CI also runs `shellcheck` on the test script and `actionlint` (which runs
shellcheck over each workflow's `run:` blocks). Locally:

```bash
actionlint
```

The tests stub `gh`, so they don't show that GitHub accepts the calls. Before
relying on the workflow in a repo, watch its first few Dependabot PRs.
