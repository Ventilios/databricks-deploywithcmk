[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [string] $SubscriptionId,

  [Parameter(Mandatory)]
  [string] $Location,

  # Short prefix used to generate unique resource names.
  [ValidateLength(1, 10)]
  [string] $Prefix = 'cmk',

  [ValidateSet('premium','standard','trial')]
  [string] $SkuName = 'premium',

  # When set, deletes both the deployment RG and the Databricks managed RG.
  [switch] $Cleanup,

  # When set with -Cleanup, waits for deletions to complete.
  [switch] $Wait
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$deployScript = Join-Path $repoRoot 'deploy.ps1'
$verifyScript = Join-Path $repoRoot 'verify.ps1'
$cleanupScript = Join-Path $repoRoot 'cleanup.ps1'

function New-Suffix {
  # Lowercase 6 chars from a GUID is enough to avoid collisions.
  return (([Guid]::NewGuid().ToString('N')).Substring(0, 6)).ToLowerInvariant()
}

function Truncate {
  param(
    [Parameter(Mandatory)][string] $Value,
    [Parameter(Mandatory)][int] $MaxLength
  )
  if ($Value.Length -le $MaxLength) { return $Value }
  return $Value.Substring(0, $MaxLength)
}

$suffix = New-Suffix
$prefixClean = ($Prefix -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($prefixClean)) { $prefixClean = 'cmk' }

$resourceGroupName = "rg-dbx-cmk-$prefixClean-$suffix"
$workspaceName = "adb-cmk-$prefixClean-$suffix"

# Key Vault name constraints are strict; use only lowercase letters/numbers and keep <= 24.
# Start with a letter; avoid hyphens for maximum compatibility.
$keyVaultBase = "kv$prefixClean$suffix"
$keyVaultName = Truncate -Value $keyVaultBase -MaxLength 24

Write-Host '== Smoke test: PUBLIC Databricks CMK deployment ==' -ForegroundColor Green
Write-Host "SubscriptionId:   $SubscriptionId" -ForegroundColor DarkGray
Write-Host "Location:         $Location" -ForegroundColor DarkGray
Write-Host "ResourceGroupName:$resourceGroupName" -ForegroundColor DarkGray
Write-Host "WorkspaceName:    $workspaceName" -ForegroundColor DarkGray
Write-Host "KeyVaultName:     $keyVaultName" -ForegroundColor DarkGray

if ($PSCmdlet.ShouldProcess($resourceGroupName, 'Deploy Databricks + Key Vault + CMK (public)')) {
  & $deployScript `
    -SubscriptionId $SubscriptionId `
    -Location $Location `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -KeyVaultName $keyVaultName `
    -SkuName $SkuName `
    -WorkspacePublicNetworkAccess Enabled `
    -KeyVaultPublicNetworkAccess Enabled `
    -KeyVaultFirewallDefaultAction Allow `
    -KeyVaultFirewallBypass AzureServices

  & $verifyScript `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -KeyVaultName $keyVaultName

  Write-Host 'Smoke test succeeded (deploy + verify).' -ForegroundColor Green

  if ($Cleanup) {
    & $cleanupScript `
      -SubscriptionId $SubscriptionId `
      -ResourceGroupName $resourceGroupName `
      -WorkspaceName $workspaceName `
      -Wait:$Wait
  } else {
    Write-Host 'Cleanup not requested. To delete resources later:' -ForegroundColor Yellow
    Write-Host "$cleanupScript -SubscriptionId '$SubscriptionId' -ResourceGroupName '$resourceGroupName' -WorkspaceName '$workspaceName' -Wait" -ForegroundColor Yellow
  }
}
