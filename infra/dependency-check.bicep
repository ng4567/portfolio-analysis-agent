targetScope = 'subscription'

@description('Subscription ID to check.')
param subscriptionId string

@description('Azure location used for temporary dependency-check resources.')
param location string = 'eastus'

@description('Resource group containing the Foundry account. Leave empty to skip deployment-level checks.')
param resourceGroupName string = ''

@description('Foundry account name to validate. Leave empty to only verify that at least one account exists.')
param foundryAccountName string = ''

@description('Model deployment names required for this project.')
param requiredDeployments array = [
  'gpt-5.4'
  'grok-4-1-fast-reasoning'
]

var checkResourceGroupName = 'portfolio-analysis-dependency-check-rg'

resource checkRg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: checkResourceGroupName
  location: location
}

module dependencyCheck './dependency-check-rg.bicep' = {
  name: 'portfolio-analysis-dependency-check-module'
  scope: checkRg
  params: {
    subscriptionId: subscriptionId
    resourceGroupName: resourceGroupName
    foundryAccountName: foundryAccountName
    requiredDeployments: requiredDeployments
  }
}

output results object = dependencyCheck.outputs.results
output checkerResourceGroup string = checkResourceGroupName
