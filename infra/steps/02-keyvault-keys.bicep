@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Key Vault (3-24 chars, alphanum and hyphen). Must be globally unique.')
param keyVaultName string

@description('Key Vault SKU name.')
@allowed([
  'standard'
  'premium'
])
param keyVaultSkuName string = 'standard'

@description('Enable RBAC authorization for data-plane actions (recommended).')
param enableRbacAuthorization bool = true

@description('Enable purge protection. WARNING: irreversible once enabled.')
param enablePurgeProtection bool = true

@description('Soft delete retention days (7-90).')
param softDeleteRetentionInDays int = 7

@description('Key Vault public network access. Keep Enabled for this repo (Private Endpoint is intentionally not supported here).')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Key Vault firewall bypass behavior.')
@allowed([
  'AzureServices'
  'None'
])
param networkAclsBypass string = 'AzureServices'

@description('Key Vault firewall default action.')
@allowed([
  'Allow'
  'Deny'
])
param networkAclsDefaultAction string = 'Allow'

@description('Optional list of subnet resource IDs to allow via Key Vault virtual network rules.')
param allowedSubnetResourceIds array = []

@description('Optional list of IPs/CIDRs to allow via Key Vault IP rules.')
param allowedIpRules array = []

@description('Key name for Databricks managed services CMK (RSA).')
param managedServicesKeyName string = 'dbx-managed-services'

@description('Key name for Databricks managed disks CMK (RSA).')
param managedDisksKeyName string = 'dbx-managed-disks'

@description('RSA key size in bits (2048/3072/4096).')
@allowed([
  2048
  3072
  4096
])
param rsaKeySize int = 4096

@description('Tags applied to the Key Vault and keys.')
param tags object = {}

var virtualNetworkRules = [
  for subnetId in allowedSubnetResourceIds: {
    id: subnetId
  }
]

var ipRules = [
  for ip in allowedIpRules: {
    value: ip
  }
]

var kvPropertiesBase = {
  tenantId: tenant().tenantId
  sku: {
    family: 'A'
    name: keyVaultSkuName
  }

  // With RBAC enabled, accessPolicies are ignored, but providing an empty list keeps the API happy.
  accessPolicies: []

  enableRbacAuthorization: enableRbacAuthorization
  enableSoftDelete: true
  softDeleteRetentionInDays: softDeleteRetentionInDays

  // Keep public network enabled for bootstrap; harden later (firewall/IP allow-list) if needed.
  publicNetworkAccess: publicNetworkAccess
  networkAcls: {
    bypass: networkAclsBypass
    defaultAction: networkAclsDefaultAction
    virtualNetworkRules: virtualNetworkRules
    ipRules: ipRules
  }
}

// Some environments reject explicitly setting enablePurgeProtection=false.
// Only set the property when enabling purge protection.
var kvProperties = union(kvPropertiesBase, enablePurgeProtection ? { enablePurgeProtection: true } : {})

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: kvProperties
}

resource servicesKey 'Microsoft.KeyVault/vaults/keys@2024-11-01' = {
  name: managedServicesKeyName
  parent: kv
  properties: {
    kty: 'RSA'
    keySize: rsaKeySize
    keyOps: [
      'wrapKey'
      'unwrapKey'
    ]
    attributes: {
      enabled: true
    }
  }
  tags: tags
}

resource disksKey 'Microsoft.KeyVault/vaults/keys@2024-11-01' = {
  name: managedDisksKeyName
  parent: kv
  properties: {
    kty: 'RSA'
    keySize: rsaKeySize
    keyOps: [
      'wrapKey'
      'unwrapKey'
    ]
    attributes: {
      enabled: true
    }
  }
  tags: tags
}

var servicesKeyParts = split(servicesKey.properties.keyUriWithVersion, '/')
var disksKeyParts = split(disksKey.properties.keyUriWithVersion, '/')

output keyVaultResourceId string = kv.id
output keyVaultUri string = kv.properties.vaultUri

output managedServicesKeyUriWithVersion string = servicesKey.properties.keyUriWithVersion
output managedServicesKeyVersion string = servicesKeyParts[length(servicesKeyParts) - 1]

output managedDisksKeyUriWithVersion string = disksKey.properties.keyUriWithVersion
output managedDisksKeyVersion string = disksKeyParts[length(disksKeyParts) - 1]
