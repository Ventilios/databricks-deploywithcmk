# Example verification invocation
# 1) az login
# 2) ./infra/examples/verify.example.ps1

$subscriptionId = '<sub-guid>'
$resourceGroupName = 'rg-dbx-cmk'
$workspaceName = 'adb-cmk-demo-001'
$keyVaultName = 'kvdbxcmkdemo001'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\\..')
$verifyScript = Join-Path $repoRoot 'verify.ps1'

& $verifyScript \
  -SubscriptionId $subscriptionId \
  -ResourceGroupName $resourceGroupName \
  -WorkspaceName $workspaceName \
  -KeyVaultName $keyVaultName
