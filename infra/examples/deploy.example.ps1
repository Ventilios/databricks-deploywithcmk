# Example invocation
# 1) az login
# 2) ./infra/examples/deploy.example.ps1

$subscriptionId = '<sub-guid>'
$location = '<region>'
$resourceGroupName = 'rg-dbx-cmk'
$workspaceName = 'adb-cmk-demo-001'
$keyVaultName = 'kvdbxcmkdemo001'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\\..')
$deployScript = Join-Path $repoRoot 'deploy.ps1'

& $deployScript \
  -SubscriptionId $subscriptionId \
  -Location $location \
  -ResourceGroupName $resourceGroupName \
  -WorkspaceName $workspaceName \
  -KeyVaultName $keyVaultName \
  -SkuName 'premium'

# Supported scenarios:
# 1) Public (simple): run deploy.ps1 as-is above.
# 2) Secure networking: use the smoke helper which creates the VNet/subnets and applies firewall rules:
#    ./infra/examples/smoke.secure.ps1 -SubscriptionId $subscriptionId -Location $location
#
# Or, if you are supplying your own VNet/subnets, add:
#   -EnableVnetInjection -EnableNoPublicIp $true
#   -KeyVaultFirewallDefaultAction Deny -KeyVaultFirewallBypass AzureServices -AllowKeyVaultFromDatabricksSubnets
