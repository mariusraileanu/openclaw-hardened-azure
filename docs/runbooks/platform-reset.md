# Platform Reset Runbook

Canonical rebuild instructions moved from `REBUILD.md`.

Use this when a destructive infra reset is required.

User discovery source: `config/users/*.env`.

## Full reset

```bash
./platform/cli/ocp reset --env dev
```

## Non-interactive

```bash
./platform/cli/ocp reset --env dev --force
```

## Split operations

```bash
./platform/cli/ocp reset --env dev --nuke-only
./platform/cli/ocp reset --env dev --rebuild-only
```

## Makefile aliases

```bash
make nuke-all ENV=dev
make rebuild-all ENV=dev
make full-rebuild ENV=dev
```

`platform-reset.sh` remains as the internal reset engine, but operator entry should be `ocp reset`.

For deep caveats and troubleshooting, see `REBUILD.md`.
