@description('Azure region for the Databricks workspace. Must match existing workspace location.')
param location string

@description('Resource group ID of the Databricks managed resource group (required by the Databricks RP on update).')
param managedResourceGroupId string

@description('Name of the Azure Databricks workspace to update.')
param workspaceName string

@description('Name of the Key Vault (must exist).')
param keyVaultName string

@description('Key name for Databricks managed services CMK (must exist).')
param managedServicesKeyName string

@description('Key name for Databricks managed disks CMK (must exist).')
param managedDisksKeyName string

@description('Enable auto-rotation to latest key version for managed disks encryption.')
param managedDisksAutoRotation bool = true

@description('Tags applied to the Databricks workspace (leave empty to avoid tag changes).')
param tags object = {}

@description('Azure Databricks SKU name. Must match the existing workspace SKU.')
@allowed([
  'premium'
  'standard'
  'trial'
])
param skuName string = 'premium'

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource servicesKey 'Microsoft.KeyVault/vaults/keys@2024-11-01' existing = {
  name: managedServicesKeyName
  parent: kv
}

resource disksKey 'Microsoft.KeyVault/vaults/keys@2024-11-01' existing = {
  name: managedDisksKeyName
  parent: kv
}

var keyVaultUri = kv.properties.vaultUri

var servicesKeyParts = split(servicesKey.properties.keyUriWithVersion, '/')
var servicesKeyVersion = servicesKeyParts[length(servicesKeyParts) - 1]

var disksKeyParts = split(disksKey.properties.keyUriWithVersion, '/')
var disksKeyVersion = disksKeyParts[length(disksKeyParts) - 1]

resource workspace 'Microsoft.Databricks/workspaces@2024-05-01' = {
  name: workspaceName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    managedResourceGroupId: managedResourceGroupId

    publicNetworkAccess: 'Enabled'

    parameters: {
      prepareEncryption: {
        value: true
      }

      // DBFS root (workspace storage account) CMK configuration.
      // This is configured via the workspace custom parameter 'encryption'.
      encryption: {
        value: {
          keySource: 'Microsoft.Keyvault'

          // The Databricks RP expects these exact property names.
          KeyName: managedServicesKeyName
          keyvaulturi: keyVaultUri
          keyversion: servicesKeyVersion
        }
      }
    }

    encryption: {
      entities: {
        managedServices: {
          keySource: 'Microsoft.Keyvault'
          keyVaultProperties: {
            keyName: managedServicesKeyName
            keyVaultUri: keyVaultUri
            keyVersion: servicesKeyVersion
          }
        }
        managedDisk: {
          keySource: 'Microsoft.Keyvault'
          keyVaultProperties: {
            keyName: managedDisksKeyName
            keyVaultUri: keyVaultUri
            keyVersion: disksKeyVersion
          }
          rotationToLatestKeyVersionEnabled: managedDisksAutoRotation
        }
      }
    }
  }
}

output workspaceResourceId string = workspace.id
output keyVaultUri string = keyVaultUri
output managedServicesKeyVersion string = servicesKeyVersion
output managedDisksKeyVersion string = disksKeyVersion
