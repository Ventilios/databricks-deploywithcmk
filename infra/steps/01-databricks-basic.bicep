@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Azure Databricks workspace.')
param workspaceName string

@description('Name of the managed resource group that Azure Databricks will create/manage.')
param managedResourceGroupName string = '${workspaceName}-managed'

@description('Azure Databricks SKU name.')
@allowed([
  'premium'
  'standard'
  'trial'
])
param skuName string = 'premium'

@description('Controls whether the workspace is deployed with VNet injection (customVirtualNetworkId/custom*SubnetName).')
param enableVnetInjection bool = false

@description('Resource ID of the virtual network for VNet injection (required when enableVnetInjection=true).')
param customVirtualNetworkId string = ''

@description('Name of the delegated public subnet in the VNet (required when enableVnetInjection=true).')
param customPublicSubnetName string = ''

@description('Name of the delegated private subnet in the VNet (required when enableVnetInjection=true).')
param customPrivateSubnetName string = ''

@description('Whether to disable public IPs on the workspace compute (recommended with VNet injection).')
param enableNoPublicIp bool = true

@description('Public network access for the workspace control plane endpoint.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Tags applied to the Azure Databricks workspace.')
param tags object = {}

var managedResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', managedResourceGroupName)

var vnetInjectionParameters = enableVnetInjection ? {
  customVirtualNetworkId: {
    value: customVirtualNetworkId
  }
  customPublicSubnetName: {
    value: customPublicSubnetName
  }
  customPrivateSubnetName: {
    value: customPrivateSubnetName
  }
  enableNoPublicIp: {
    value: enableNoPublicIp
  }
} : {}

resource workspace 'Microsoft.Databricks/workspaces@2024-05-01' = {
  name: workspaceName
  location: location
  sku: {
    name: skuName
  }
  tags: tags
  properties: {
    // Required on both create and update
    managedResourceGroupId: managedResourceGroupId

    // Optional: keep public access enabled for initial bootstrap
    publicNetworkAccess: publicNetworkAccess
    // Required for managed services CMK: enables managed identity on the managed storage account
    // VNet injection parameters are included only when enableVnetInjection=true.
    parameters: union({
      prepareEncryption: {
        value: true
      }
    }, vnetInjectionParameters)
  }
}

output managedResourceGroupId string = managedResourceGroupId
output managedResourceGroupName string = managedResourceGroupName
output workspaceUrl string = workspace.properties.workspaceUrl
