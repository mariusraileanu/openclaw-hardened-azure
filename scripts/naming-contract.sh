#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
target_var="${2:-}"

ENV_NAME="${ENV_NAME:-${AZURE_ENVIRONMENT:-dev}}"

default_azure_resource_group="rg-openclaw-${ENV_NAME}"
default_azure_containerapps_env="cae-openclaw-${ENV_NAME}"
default_azure_acr_name="acropenclaw${ENV_NAME}"
default_azure_key_vault_name="kvopenclaw${ENV_NAME}"
default_nfs_sa_name="nfsopenclaw${ENV_NAME}"
default_cae_nfs_storage_name="openclaw-nfs-${ENV_NAME}"
default_tf_state_rg="rg-openclaw-tfstate-${ENV_NAME}"
default_tf_state_sa="tfopenclawstate${ENV_NAME}"
default_tf_state_key="shared.tfstate"
default_sa_name="stocopenclaw${ENV_NAME}"
default_func_relay_name="func-relay-openclaw-${ENV_NAME}"

resolve() {
  local name="$1"
  local fallback="$2"
  local value="${!name:-}"
  if [[ -n "$value" ]]; then
    printf "%s" "$value"
  else
    printf "%s" "$fallback"
  fi
}

AZURE_RESOURCE_GROUP_RESOLVED="$(resolve AZURE_RESOURCE_GROUP "${default_azure_resource_group}")"
AZURE_CONTAINERAPPS_ENV_RESOLVED="$(resolve AZURE_CONTAINERAPPS_ENV "${default_azure_containerapps_env}")"
AZURE_ACR_NAME_RESOLVED="$(resolve AZURE_ACR_NAME "${default_azure_acr_name}")"
AZURE_KEY_VAULT_NAME_RESOLVED="$(resolve AZURE_KEY_VAULT_NAME "${default_azure_key_vault_name}")"
NFS_SA_NAME_RESOLVED="$(resolve NFS_SA_NAME "${default_nfs_sa_name}")"
CAE_NFS_STORAGE_NAME_RESOLVED="$(resolve CAE_NFS_STORAGE_NAME "${default_cae_nfs_storage_name}")"
TF_STATE_RG_RESOLVED="$(resolve TF_STATE_RG "${default_tf_state_rg}")"
TF_STATE_SA_RESOLVED="$(resolve TF_STATE_SA "${default_tf_state_sa}")"
TF_STATE_KEY_RESOLVED="$(resolve TF_STATE_KEY "${default_tf_state_key}")"
ACR_NAME_RESOLVED="$(resolve ACR_NAME "${AZURE_ACR_NAME_RESOLVED}")"
SA_NAME_RESOLVED="$(resolve SA_NAME "${default_sa_name}")"
FUNC_RELAY_NAME_RESOLVED="$(resolve FUNC_RELAY_NAME "${default_func_relay_name}")"

check_pattern() {
  local value="$1"
  local regex="$2"
  local label="$3"
  if [[ ! "$value" =~ $regex ]]; then
    echo "INVALID: ${label}='${value}'" >&2
    return 1
  fi
}

validate() {
  local failures=0

check_pattern "${ENV_NAME}" '^[a-z0-9-]{2,20}$' "ENV_NAME" || failures=$((failures + 1))
check_pattern "${AZURE_RESOURCE_GROUP_RESOLVED}" '^rg-[a-z0-9-]{1,85}$' "AZURE_RESOURCE_GROUP" || failures=$((failures + 1))
check_pattern "${AZURE_CONTAINERAPPS_ENV_RESOLVED}" '^cae-[a-z0-9-]{1,55}$' "AZURE_CONTAINERAPPS_ENV" || failures=$((failures + 1))
check_pattern "${AZURE_ACR_NAME_RESOLVED}" '^[a-z0-9]{5,50}$' "AZURE_ACR_NAME" || failures=$((failures + 1))
check_pattern "${AZURE_KEY_VAULT_NAME_RESOLVED}" '^[a-z0-9-]{3,24}$' "AZURE_KEY_VAULT_NAME" || failures=$((failures + 1))
check_pattern "${NFS_SA_NAME_RESOLVED}" '^[a-z0-9]{3,24}$' "NFS_SA_NAME" || failures=$((failures + 1))
check_pattern "${CAE_NFS_STORAGE_NAME_RESOLVED}" '^[a-z0-9-]{3,63}$' "CAE_NFS_STORAGE_NAME" || failures=$((failures + 1))
check_pattern "${TF_STATE_RG_RESOLVED}" '^rg-[a-z0-9-]{1,85}$' "TF_STATE_RG" || failures=$((failures + 1))
check_pattern "${TF_STATE_SA_RESOLVED}" '^[a-z0-9]{3,24}$' "TF_STATE_SA" || failures=$((failures + 1))
check_pattern "${TF_STATE_KEY_RESOLVED}" '^[a-zA-Z0-9._/-]{3,200}$' "TF_STATE_KEY" || failures=$((failures + 1))
check_pattern "${ACR_NAME_RESOLVED}" '^[a-z0-9]{5,50}$' "ACR_NAME" || failures=$((failures + 1))
check_pattern "${SA_NAME_RESOLVED}" '^[a-z0-9]{3,24}$' "SA_NAME" || failures=$((failures + 1))
check_pattern "${FUNC_RELAY_NAME_RESOLVED}" '^[a-z0-9-]{3,60}$' "FUNC_RELAY_NAME" || failures=$((failures + 1))

  if (( failures > 0 )); then
    echo "Naming contract validation failed with ${failures} error(s)." >&2
    return 1
  fi

  echo "Naming contract OK: ENV=${ENV_NAME} RG=${AZURE_RESOURCE_GROUP_RESOLVED} CAE=${AZURE_CONTAINERAPPS_ENV_RESOLVED} ACR=${AZURE_ACR_NAME_RESOLVED}" >&2
}

print_exports() {
  cat <<EOF
export AZURE_RESOURCE_GROUP='${AZURE_RESOURCE_GROUP_RESOLVED}'
export AZURE_CONTAINERAPPS_ENV='${AZURE_CONTAINERAPPS_ENV_RESOLVED}'
export AZURE_ACR_NAME='${AZURE_ACR_NAME_RESOLVED}'
export AZURE_KEY_VAULT_NAME='${AZURE_KEY_VAULT_NAME_RESOLVED}'
export NFS_SA_NAME='${NFS_SA_NAME_RESOLVED}'
export CAE_NFS_STORAGE_NAME='${CAE_NFS_STORAGE_NAME_RESOLVED}'
export TF_STATE_RG='${TF_STATE_RG_RESOLVED}'
export TF_STATE_SA='${TF_STATE_SA_RESOLVED}'
export TF_STATE_KEY='${TF_STATE_KEY_RESOLVED}'
export ACR_NAME='${ACR_NAME_RESOLVED}'
export SA_NAME='${SA_NAME_RESOLVED}'
export FUNC_RELAY_NAME='${FUNC_RELAY_NAME_RESOLVED}'
EOF
}

case "${action}" in
  export)
    print_exports
    ;;
  validate)
    validate
    ;;
  get)
    case "${target_var}" in
      AZURE_RESOURCE_GROUP) printf "%s\n" "${AZURE_RESOURCE_GROUP_RESOLVED}" ;;
      AZURE_CONTAINERAPPS_ENV) printf "%s\n" "${AZURE_CONTAINERAPPS_ENV_RESOLVED}" ;;
      AZURE_ACR_NAME) printf "%s\n" "${AZURE_ACR_NAME_RESOLVED}" ;;
      AZURE_KEY_VAULT_NAME) printf "%s\n" "${AZURE_KEY_VAULT_NAME_RESOLVED}" ;;
      NFS_SA_NAME) printf "%s\n" "${NFS_SA_NAME_RESOLVED}" ;;
      CAE_NFS_STORAGE_NAME) printf "%s\n" "${CAE_NFS_STORAGE_NAME_RESOLVED}" ;;
      TF_STATE_RG) printf "%s\n" "${TF_STATE_RG_RESOLVED}" ;;
      TF_STATE_SA) printf "%s\n" "${TF_STATE_SA_RESOLVED}" ;;
      TF_STATE_KEY) printf "%s\n" "${TF_STATE_KEY_RESOLVED}" ;;
      ACR_NAME) printf "%s\n" "${ACR_NAME_RESOLVED}" ;;
      SA_NAME) printf "%s\n" "${SA_NAME_RESOLVED}" ;;
      FUNC_RELAY_NAME) printf "%s\n" "${FUNC_RELAY_NAME_RESOLVED}" ;;
      *)
        echo "Unknown variable for get: ${target_var}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Usage: $0 {export|validate|get <VAR>}" >&2
    exit 1
    ;;
esac
