# Contributing to PowerDNS OCM

Thank you for your interest in contributing! Contributions of all kinds are welcome —
bug reports, documentation improvements, and code changes.

## Reporting Issues

Open a GitHub issue and include:

- A clear description of the problem or suggestion
- Steps to reproduce (for bugs)
- Relevant environment details (Kubernetes version, OCM CLI version, etc.)

## Development Setup

1. Fork the repository and clone your fork.
2. Ensure you have the required tools installed (Kubernetes 1.27+, OCM CLI, KRO).
3. Create a branch for your change (see [Branching](#branching)).
4. Make your changes and commit them.
5. Open a pull request against `main`.

## Branching

Use a short, descriptive branch name with one of the following prefixes:

| Prefix | When to use |
|---|---|
| `feature/` | New functionality |
| `bugfix/` | Bug fixes |
| `docs/` | Documentation-only changes |
| `refactor/` | Code restructuring without behaviour change |
| `chore/` | Tooling, dependencies, CI |

Examples: `feature/dnsdist-metrics`, `bugfix/recursor-crashloop`, `docs/air-gap-guide`.

If your change addresses a GitHub issue, you may include the issue number:
`bugfix/42-recursor-crashloop`.

## Commit Messages

Use clear, imperative commit messages that explain the change:

```text
Add OCM package validation workflow
```

For larger changes, include a short body that explains why the change is needed and what operational impact it has.

## Pull Requests

- Target the `main` branch.
- Keep the scope of a PR to a single logical change.
- Write a clear PR description explaining what changed and why.
- Ensure existing checks pass before submitting.
- At least one approving review is required before merge.
- Required GitHub Actions checks must pass before merge, and review conversations must be resolved.
- Update documentation when behavior, prerequisites, workflows, or operator-facing procedures change.

## Required Checks

Pull requests are expected to pass the repository GitHub Actions workflow before merge. The workflow validates:

- YAML, shell scripts, and GitHub Actions syntax
- Approved and pinned GitHub Actions usage
- Secret scanning
- Kustomize rendering and Kubernetes schema validation
- OCM package build and validation
- CVE scans for container images declared in the OCM component descriptor

Deployment smoke tests run automatically only when the repository has a test-cluster kubeconfig configured.

## Code Style

Follow the conventions already present in the codebase. Consistency matters
more than personal preference.

## License

By contributing you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
