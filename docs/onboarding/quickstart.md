# Quickstart

This is the fastest safe path for first-time setup.

## Prerequisites

- Azure CLI authenticated (`az login`)
- Terraform 1.5+
- Docker (for local container run only)

## 1) Create config files

```bash
./platform/cli/ocp config bootstrap --env dev --user alice
```

Edit layered config inputs:

- `config/env/dev.env` (shared non-secret overrides)
- `config/users/alice.env` (per-user non-secret overrides)
- `config/local/dev.env` and `config/local/dev.alice.env` (optional local overrides)

Optional local overrides (if you use them):

```bash
cp config/local/dev.example.env config/local/dev.env
cp config/local/prod.example.env config/local/prod.env
```

## 2) Validate naming and repository hygiene

```bash
./platform/cli/ocp doctor --env dev --user alice
make naming-check ENV=dev
make hygiene-check
./platform/cli/ocp config validate --env dev --user alice
```

## 3) Deploy shared platform

```bash
./platform/cli/ocp deploy shared --env dev
```

## 4) Build and push golden image

```bash
make build-image ENV=dev
```

## 5) Deploy user app

```bash
./platform/cli/ocp deploy user --env dev --user alice
```

## 6) Verify

```bash
./platform/cli/ocp status --env dev --user alice
./platform/cli/ocp logs --env dev --user alice
```

## Optional local-only run

```bash
make docker-up
make docker-down
```
