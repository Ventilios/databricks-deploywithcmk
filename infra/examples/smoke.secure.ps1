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

  # Creates a NAT Gateway for stable outbound from subnets.
  [bool] $CreateNatGateway = $true,

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

$resourceGroupName = "rg-dbx-cmk-sec-$prefixClean-$suffix"
$workspaceName = "adb-cmk-sec-$prefixClean-$suffix"

# Key Vault name constraints: only lowercase letters/numbers; 3-24.
$keyVaultBase = "kv$prefixClean$suffix"
$keyVaultName = Truncate -Value $keyVaultBase -MaxLength 24

Write-Host '== Smoke test: SECURE networking Databricks CMK deployment ==' -ForegroundColor Green
Write-Host "SubscriptionId:   $SubscriptionId" -ForegroundColor DarkGray
Write-Host "Location:         $Location" -ForegroundColor DarkGray
Write-Host "ResourceGroupName:$resourceGroupName" -ForegroundColor DarkGray
Write-Host "WorkspaceName:    $workspaceName" -ForegroundColor DarkGray
Write-Host "KeyVaultName:     $keyVaultName" -ForegroundColor DarkGray

Write-Host 'Mode:' -ForegroundColor Cyan
Write-Host '- VNet injection enabled (no public IPs for compute)' -ForegroundColor Cyan
Write-Host '- Key Vault firewall: defaultAction=Deny, bypass=AzureServices' -ForegroundColor Cyan
Write-Host '- Key Vault allows Databricks subnets (VNet rules)' -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($resourceGroupName, 'Deploy Databricks + Key Vault + CMK (secure networking)')) {
  & $deployScript `
    -SubscriptionId $SubscriptionId `
    -Location $Location `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -KeyVaultName $keyVaultName `
    -SkuName $SkuName `
    -EnableVnetInjection `
    -EnableNoPublicIp $true `
    -CreateNatGateway $CreateNatGateway `
    -WorkspacePublicNetworkAccess Enabled `
    -KeyVaultPublicNetworkAccess Enabled `
    -KeyVaultFirewallDefaultAction Deny `
    -KeyVaultFirewallBypass AzureServices `
    -AllowKeyVaultFromDatabricksSubnets

  & $verifyScript `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -KeyVaultName $keyVaultName

  Write-Host 'Secure networking smoke test succeeded (deploy + verify).' -ForegroundColor Green

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
