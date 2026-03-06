#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f ".env" ]]; then
  echo "Missing .env file. Create it from .env.template first."
  exit 1
fi

set -a
source .env
set +a

if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
  echo "AZURE_SUBSCRIPTION_ID is required in .env"
  exit 1
fi

LOCATION="${AZURE_LOCATION:-eastus}"
RG_NAME="${RESOURCE_GROUP_NAME:-}"
ACCOUNT_NAME="${FOUNDRY_ACCOUNT_NAME:-}"
TEMPLATE_PATH="infra/dependency-check.bicep"
DEPLOYMENT_NAME="dependency-check-$(date +%s)"
REQUIRED_DEPLOYMENTS="${REQUIRED_DEPLOYMENTS:-gpt-5.4,grok-4-1-fast-reasoning}"
USE_BICEP_CHECK="${USE_BICEP_CHECK:-false}"

run_local_check() {
  foundry_accounts_json=$(az resource list \
    --subscription "${AZURE_SUBSCRIPTION_ID}" \
    --resource-type "Microsoft.CognitiveServices/accounts" \
    -o json)
  foundry_count=$(echo "${foundry_accounts_json}" | jq 'length')

  declare -a missing=()
  declare -a recommendations=()

  if [[ "${foundry_count}" -eq 0 ]]; then
    missing+=("Azure AI Foundry account (Microsoft.CognitiveServices/accounts)")
    recommendations+=("Provision an Azure AI Foundry account in the target subscription.")
  fi

  if [[ -n "${ACCOUNT_NAME}" ]]; then
    account_match_count=$(echo "${foundry_accounts_json}" | jq --arg name "${ACCOUNT_NAME}" '[.[] | select(.name == $name)] | length')
    if [[ "${account_match_count}" -eq 0 ]]; then
      missing+=("Foundry account named '${ACCOUNT_NAME}'")
      recommendations+=("Provision Foundry account '${ACCOUNT_NAME}' or update FOUNDRY_ACCOUNT_NAME in .env.")
    fi
  fi

  if [[ -n "${RG_NAME}" && -n "${ACCOUNT_NAME}" ]]; then
    deployment_names=$(az cognitiveservices account deployment list \
      -g "${RG_NAME}" \
      -n "${ACCOUNT_NAME}" \
      --subscription "${AZURE_SUBSCRIPTION_ID}" \
      --query "[].name" \
      -o tsv 2>/dev/null || true)

    IFS=',' read -r -a required_array <<< "${REQUIRED_DEPLOYMENTS}"
    for deployment in "${required_array[@]}"; do
      deployment_trimmed="$(echo "${deployment}" | xargs)"
      if [[ -n "${deployment_trimmed}" ]] && ! echo "${deployment_names}" | tr ' ' '\n' | grep -Fxq "${deployment_trimmed}"; then
        missing+=("Model deployment '${deployment_trimmed}'")
        recommendations+=("Deploy model '${deployment_trimmed}' to Foundry account '${ACCOUNT_NAME}'.")
      fi
    done
  else
    recommendations+=("Set RESOURCE_GROUP_NAME and FOUNDRY_ACCOUNT_NAME in .env to enable deployment-level checks.")
  fi

  status="ok"
  if [[ "${#missing[@]}" -gt 0 ]]; then
    status="missing_dependencies"
  fi

  missing_json='[]'
  recommendations_json='[]'
  if [[ "${#missing[@]}" -gt 0 ]]; then
    missing_json=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)
  fi
  if [[ "${#recommendations[@]}" -gt 0 ]]; then
    recommendations_json=$(printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s .)
  fi

  jq -n \
    --arg status "${status}" \
    --argjson foundryCount "${foundry_count}" \
    --argjson missing "${missing_json}" \
    --argjson recommendations "${recommendations_json}" \
    '{
      status: $status,
      foundryAccountCount: $foundryCount,
      missing: $missing,
      recommendations: $recommendations
    }'
}

echo "Running dependency check in subscription: ${AZURE_SUBSCRIPTION_ID}"

if [[ "${USE_BICEP_CHECK}" != "true" ]]; then
  run_local_check
  exit 0
fi

echo "USE_BICEP_CHECK=true, running ARM/Bicep dependency check..." >&2

set +e
deployment_output=$(
az deployment sub create \
  --name "${DEPLOYMENT_NAME}" \
  --location "${LOCATION}" \
  --template-file "${TEMPLATE_PATH}" \
  --parameters \
    subscriptionId="${AZURE_SUBSCRIPTION_ID}" \
    location="${LOCATION}" \
    resourceGroupName="${RG_NAME}" \
    foundryAccountName="${ACCOUNT_NAME}" \
  --query "properties.outputs.results.value" \
  -o jsonc 2>&1
)
deployment_status=$?
set -e

if [[ "${deployment_status}" -eq 0 ]]; then
  echo "${deployment_output}"
  exit 0
fi

if echo "${deployment_output}" | grep -q "KeyBasedAuthenticationNotPermitted"; then
  echo "ARM deployment script blocked by storage policy (KeyBasedAuthenticationNotPermitted)." >&2
  echo "Falling back to local CLI dependency check..." >&2
  run_local_check
  exit 0
fi

echo "${deployment_output}" >&2
exit "${deployment_status}"
