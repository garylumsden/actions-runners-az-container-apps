# Security policy

## Reporting a vulnerability

If you find a security issue in this project, please report it privately via GitHub's
[private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
mechanism on this repository.

Please do **not** open a public issue for vulnerabilities.

## What is in scope

- Bicep templates under `infra/`
- Runner images under `docker/`
- Setup scripts under `scripts/`
- CI/CD workflows (active or disabled)

## What is out of scope

- Customer deployments of this template. Each operator is responsible for their own
  Azure subscription security posture, RBAC, and secret handling.
- Upstream dependencies (Azure services, GitHub Actions, base Docker images). Report
  those to the upstream maintainers.
