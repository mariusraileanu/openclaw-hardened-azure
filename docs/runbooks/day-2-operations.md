# Day-2 Operations

## Common commands

```bash
./platform/cli/ocp status --env dev
./platform/cli/ocp status --env dev --user alice
./platform/cli/ocp logs --env dev --user alice
./platform/cli/ocp deploy user --env dev --user alice --plan
./platform/cli/ocp deploy user --env dev --user alice
./platform/cli/ocp user remove --env dev --user alice
```

## Add a new user

```bash
cp config/users/user.example.env config/users/bob.env
# edit config/users/bob.env
./platform/cli/ocp config validate --env dev --user bob
./platform/cli/ocp deploy user --env dev --user bob
```

## Redeploy image for a user

```bash
make build-image ENV=dev IMAGE_TAG=v1.0.1
IMAGE_TAG=v1.0.1 ./platform/cli/ocp deploy user --env dev --user alice
```

## Signal operations

```bash
./platform/cli/ocp signal status --env dev
./platform/cli/ocp signal logs-cli --env dev
./platform/cli/ocp signal logs-proxy --env dev
./platform/cli/ocp signal register --env dev
```

## Teams operations

```bash
./platform/cli/ocp teams release-check
./platform/cli/ocp teams relay-build --env dev
./platform/cli/ocp teams relay-deploy --env dev
```

## OCP-first flow

Use `ocp` for all operational actions. Keep `make` as compatibility aliases.

```bash
./platform/cli/ocp config bootstrap --env dev --user alice
./platform/cli/ocp config validate --env dev --user alice
./platform/cli/ocp deploy shared --env dev
./platform/cli/ocp deploy user --env dev --user alice
```

## Before any commit

```bash
make hygiene-check
```
