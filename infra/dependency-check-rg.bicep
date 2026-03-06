targetScope = 'resourceGroup'

@description('Subscription ID to check.')
param subscriptionId string

@description('Resource group containing the Foundry account. Leave empty to skip deployment-level checks.')
param resourceGroupName string = ''

@description('Foundry account name to validate. Leave empty to only verify that at least one account exists.')
param foundryAccountName string = ''

@description('Model deployment names required for this project.')
param requiredDeployments array = [
  'gpt-5.4'
  'grok-4-1-fast-reasoning'
]

resource dependencyCheckScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'portfolio-analysis-dependency-check'
  location: resourceGroup().location
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.63.0'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    timeout: 'PT15M'
    environmentVariables: [
      {
        name: 'CHECK_SUBSCRIPTION_ID'
        value: subscriptionId
      }
      {
        name: 'CHECK_RESOURCE_GROUP_NAME'
        value: resourceGroupName
      }
      {
        name: 'CHECK_FOUNDRY_ACCOUNT_NAME'
        value: foundryAccountName
      }
      {
        name: 'CHECK_REQUIRED_DEPLOYMENTS'
        value: join(requiredDeployments, ',')
      }
    ]
    scriptContent: '''
      #!/usr/bin/env bash
      set -euo pipefail

      SUB_ID="$CHECK_SUBSCRIPTION_ID"
      RG_NAME="$CHECK_RESOURCE_GROUP_NAME"
      ACCOUNT_NAME="$CHECK_FOUNDRY_ACCOUNT_NAME"
      REQUIRED_DEPLOYMENTS="$CHECK_REQUIRED_DEPLOYMENTS"

      foundry_accounts_json=$(az resource list \
        --subscription "$SUB_ID" \
        --resource-type "Microsoft.CognitiveServices/accounts" \
        -o json)

      foundry_count=$(echo "$foundry_accounts_json" | jq 'length')
      missing=()
      recommendations=()

      if [[ "$foundry_count" -eq 0 ]]; then
        missing+=("Azure AI Foundry account (Microsoft.CognitiveServices/accounts)")
        recommendations+=("Provision an Azure AI Foundry account in the target subscription.")
      fi

      if [[ -n "$ACCOUNT_NAME" ]]; then
        account_match_count=$(echo "$foundry_accounts_json" | jq --arg name "$ACCOUNT_NAME" '[.[] | select(.name == $name)] | length')
        if [[ "$account_match_count" -eq 0 ]]; then
          missing+=("Foundry account named '$ACCOUNT_NAME'")
          recommendations+=("Provision Foundry account '$ACCOUNT_NAME' or update FOUNDRY_ACCOUNT_NAME in .env.")
        fi
      fi

      if [[ -n "$RG_NAME" && -n "$ACCOUNT_NAME" ]]; then
        deployment_names=$(az cognitiveservices account deployment list \
          -g "$RG_NAME" \
          -n "$ACCOUNT_NAME" \
          --subscription "$SUB_ID" \
          --query "[].name" \
          -o tsv || true)

        IFS=',' read -r -a required_array <<< "$REQUIRED_DEPLOYMENTS"
        for deployment in "${required_array[@]}"; do
          deployment_trimmed="$(echo "$deployment" | xargs)"
          if [[ -n "$deployment_trimmed" ]] && ! echo "$deployment_names" | tr ' ' '\n' | grep -Fxq "$deployment_trimmed"; then
            missing+=("Model deployment '$deployment_trimmed'")
            recommendations+=("Deploy model '$deployment_trimmed' to Foundry account '$ACCOUNT_NAME'.")
          fi
        done
      else
        recommendations+=("Set RESOURCE_GROUP_NAME and FOUNDRY_ACCOUNT_NAME in .env to enable deployment-level checks.")
      fi

      status="ok"
      if [[ "${#missing[@]}" -gt 0 ]]; then
        status="missing_dependencies"
      fi

      jq -n \
        --arg status "$status" \
        --argjson foundryCount "$foundry_count" \
        --argjson missing "$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)" \
        --argjson recommendations "$(printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s .)" \
        '{
          status: $status,
          foundryAccountCount: $foundryCount,
          missing: $missing,
          recommendations: $recommendations
        }' > "$AZ_SCRIPTS_OUTPUT_PATH"
    '''
  }
}

output results object = dependencyCheckScript.properties.outputs
