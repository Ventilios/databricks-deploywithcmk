@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the virtual network to create for Azure Databricks VNet injection.')
param vnetName string

@description('VNet address space CIDR.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Subnet name for Azure Databricks public subnet (host).')
param databricksPublicSubnetName string = 'snet-dbx-public'

@description('CIDR for the Databricks public subnet.')
param databricksPublicSubnetPrefix string = '10.10.1.0/24'

@description('Subnet name for Azure Databricks private subnet (container).')
param databricksPrivateSubnetName string = 'snet-dbx-private'

@description('CIDR for the Databricks private subnet.')
param databricksPrivateSubnetPrefix string = '10.10.2.0/24'

@description('Whether to deploy a NAT Gateway for stable outbound from the Databricks subnets.')
param createNatGateway bool = true

@description('NAT Gateway name (only used when createNatGateway=true).')
param natGatewayName string = 'ngw-${vnetName}'

@description('Public IP name for NAT Gateway (only used when createNatGateway=true).')
param natPublicIpName string = 'pip-${vnetName}-ngw'

@description('Tags applied to network resources.')
param tags object = {}

var publicNsgName = 'nsg-${vnetName}-dbx-public'
var privateNsgName = 'nsg-${vnetName}-dbx-private'

resource publicNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: publicNsgName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource privateNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: privateNsgName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (createNatGateway) {
  name: natPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = if (createNatGateway) {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: databricksPublicSubnetName
        properties: {
          addressPrefix: databricksPublicSubnetPrefix
          delegations: [
            {
              name: 'databricks'
              properties: {
                serviceName: 'Microsoft.Databricks/workspaces'
              }
            }
          ]
          networkSecurityGroup: {
            id: publicNsg.id
          }
          natGateway: createNatGateway ? {
            id: natGateway.id
          } : null
          serviceEndpoints: [
            {
              service: 'Microsoft.KeyVault'
            }
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: databricksPrivateSubnetName
        properties: {
          addressPrefix: databricksPrivateSubnetPrefix
          delegations: [
            {
              name: 'databricks'
              properties: {
                serviceName: 'Microsoft.Databricks/workspaces'
              }
            }
          ]
          networkSecurityGroup: {
            id: privateNsg.id
          }
          natGateway: createNatGateway ? {
            id: natGateway.id
          } : null
          serviceEndpoints: [
            {
              service: 'Microsoft.KeyVault'
            }
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
    ]
  }
}

output virtualNetworkId string = vnet.id
output databricksPublicSubnetName string = databricksPublicSubnetName
output databricksPrivateSubnetName string = databricksPrivateSubnetName
output databricksPublicSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, databricksPublicSubnetName)
output databricksPrivateSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, databricksPrivateSubnetName)
