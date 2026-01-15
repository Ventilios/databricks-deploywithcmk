[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $SubscriptionId,

  [Parameter(Mandatory)]
  [string] $Location,

  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $WorkspaceName,

  [Parameter(Mandatory)]
  [string] $KeyVaultName,

  [ValidateSet('premium','standard','trial')]
  [string] $SkuName = 'premium',

  [string] $ManagedResourceGroupName = "$WorkspaceName-managed",

  [string] $ManagedServicesKeyName = 'dbx-managed-services',

  [string] $ManagedDisksKeyName = 'dbx-managed-disks',

  [switch] $EnableVnetInjection,

  [string] $VnetName = "vnet-$WorkspaceName",

  [string] $VnetAddressPrefix = '10.10.0.0/16',

  [string] $DatabricksPublicSubnetName = 'snet-dbx-public',

  [string] $DatabricksPublicSubnetPrefix = '10.10.1.0/24',

  [string] $DatabricksPrivateSubnetName = 'snet-dbx-private',

  [string] $DatabricksPrivateSubnetPrefix = '10.10.2.0/24',

  [bool] $CreateNatGateway = $true,

  [bool] $EnableNoPublicIp = $true,

  [ValidateSet('Enabled','Disabled')]
  [string] $WorkspacePublicNetworkAccess = 'Enabled',

  [ValidateSet('Enabled','Disabled')]
  [string] $KeyVaultPublicNetworkAccess = 'Enabled',

  [ValidateSet('AzureServices','None')]
  [string] $KeyVaultFirewallBypass = 'AzureServices',

  [ValidateSet('Allow','Deny')]
  [string] $KeyVaultFirewallDefaultAction = 'Allow',

  [string[]] $KeyVaultAllowedIpRules = @(),

  [switch] $AllowKeyVaultFromDatabricksSubnets,

  [switch] $SkipStep3RoleAssignments,

  [switch] $SkipStep5PostAssignments
)

$ErrorActionPreference = 'Stop'

# Allow this script to be invoked from any working directory.
$RepoRoot = $PSScriptRoot
$Step0BicepPath = Join-Path $RepoRoot 'infra/steps/00-networking.bicep'
$Step1BicepPath = Join-Path $RepoRoot 'infra/steps/01-databricks-basic.bicep'
$Step2BicepPath = Join-Path $RepoRoot 'infra/steps/02-keyvault-keys.bicep'
$Step4BicepPath = Join-Path $RepoRoot 'infra/steps/04-enable-dbx-cmk.bicep'

function Invoke-AzCli {
  param(
    [Parameter(Mandatory)]
    [string[]] $AzCliArguments,

    [switch] $CaptureJson,

    [int] $MaxRetries = 4
  )

  $cmdDisplay = ($AzCliArguments | ForEach-Object {
      if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
  Write-Host "az $cmdDisplay" -ForegroundColor Cyan

  # If caller wants JSON but didn't specify output, force it.
  $finalArgs = @($AzCliArguments)
  if ($CaptureJson -and -not ($finalArgs -contains '-o' -or $finalArgs -contains '--output')) {
    $finalArgs += @('-o', 'json')
  }

  $attempt = 0
  $out = $null
  while ($true) {
    $attempt++
    $out = & az @finalArgs 2>&1
    if ($LASTEXITCODE -eq 0) { break }

    $outText = ($out | Out-String)
    $isTransient = ($outText -match 'ConnectionResetError|Connection aborted|ECONNRESET|read: connection reset|timed out|HTTP 5\d\d|TooManyRequests|HTTP 429')

    if ($isTransient -and $attempt -lt $MaxRetries) {
      $sleepSeconds = [Math]::Min(60, [int]([Math]::Pow(2, $attempt) * 3))
      Write-Warning "Azure CLI transient failure (attempt $attempt/$MaxRetries). Retrying in ${sleepSeconds}s..."
      Start-Sleep -Seconds $sleepSeconds
      continue
    }

    throw "Azure CLI failed (exit $LASTEXITCODE): az $cmdDisplay`n$out"
  }

  if ($CaptureJson) {
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    return $out | ConvertFrom-Json
  }

  return $out
}

function Get-ManagedRgId {
  param(
    [Parameter(Mandatory)][string] $WorkspaceName,
    [Parameter(Mandatory)][string] $ResourceGroupName
  )

  return (Invoke-AzCli -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces','--query','properties.managedResourceGroupId','-o','tsv'))
}

function Get-RgNameFromId {
  param([Parameter(Mandatory)][string] $ResourceId)

  # /subscriptions/<sub>/resourceGroups/<rg>/providers/...
  $parts = $ResourceId -split '/'
  $idx = [Array]::IndexOf($parts, 'resourceGroups')
  if ($idx -lt 0 -or ($idx + 1) -ge $parts.Length) {
    throw "Could not parse resource group name from: $ResourceId"
  }
  return $parts[$idx + 1]
}

function Test-AzResourceExists {
  param(
    [Parameter(Mandatory)][string[]] $AzCliArguments
  )

  try {
    Invoke-AzCli -AzCliArguments $AzCliArguments | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Initialize-AzPrereqs {
  # Do not run `az --version` through Invoke-AzCli: recent CLI builds can emit upgrade warnings
  # that may return a non-zero exit code in some environments.
  Write-Host 'Azure CLI version:' -ForegroundColor DarkGray
  & az --version | Out-Host

  Invoke-AzCli -AzCliArguments @('account','set','--subscription',$SubscriptionId)
}

function Assert-KeyVaultNetworkingSane {
  param(
    [Parameter(Mandatory)][object] $KeyVault
  )

  $pna = $KeyVault.properties.publicNetworkAccess
  if ($pna -eq 'Disabled') {
    throw "Key Vault publicNetworkAccess is Disabled. This repo no longer provisions private endpoints, so Databricks CMK would not be able to reach the vault."
  }

  $acls = $KeyVault.properties.networkAcls
  if ($null -ne $acls -and $acls.defaultAction -eq 'Deny' -and $acls.bypass -eq 'None') {
    $vnCount = @($acls.virtualNetworkRules).Count
    $ipCount = @($acls.ipRules).Count
    if ($vnCount -eq 0 -and $ipCount -eq 0) {
      throw "Key Vault firewall defaultAction is Deny and bypass is None with no VNet/IP rules. Refusing to continue because the vault would be unreachable."
    }
  }
}

Write-Host "== Azure Databricks CMK multi-step deploy ==" -ForegroundColor Green
Initialize-AzPrereqs

Write-Host "== Step 0: Ensure resource group ==" -ForegroundColor Green
Invoke-AzCli -AzCliArguments @('group','create','-n',$ResourceGroupName,'-l',$Location,'-o','none')

$networkOutputs = $null
if ($EnableVnetInjection -or $AllowKeyVaultFromDatabricksSubnets) {
  Write-Host "== Step 0.5: Deploy networking (VNet + subnets) ==" -ForegroundColor Green

  $netDeploy = Invoke-AzCli -AzCliArguments @(
    'deployment','group','create',
    '-g',$ResourceGroupName,
    '-f',$Step0BicepPath,
    '-p',
    "location=$Location",
    "vnetName=$VnetName",
    "vnetAddressPrefix=$VnetAddressPrefix",
    "databricksPublicSubnetName=$DatabricksPublicSubnetName",
    "databricksPublicSubnetPrefix=$DatabricksPublicSubnetPrefix",
    "databricksPrivateSubnetName=$DatabricksPrivateSubnetName",
    "databricksPrivateSubnetPrefix=$DatabricksPrivateSubnetPrefix",
    "createNatGateway=$CreateNatGateway"
  ) -CaptureJson

  $networkOutputs = $netDeploy.properties.outputs
}

Write-Host "== Step 1: Deploy basic Databricks workspace (prepareEncryption=true) ==" -ForegroundColor Green
if (Test-AzResourceExists -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces','-o','none')) {
  Write-Host "Workspace '$WorkspaceName' already exists; skipping step 1." -ForegroundColor DarkGray
} else {
  $step1Args = @(
    'deployment','group','create',
    '-g',$ResourceGroupName,
    '-f',$Step1BicepPath,
    '-p',
    "location=$Location",
    "workspaceName=$WorkspaceName",
    "managedResourceGroupName=$ManagedResourceGroupName",
    "skuName=$SkuName",
    "publicNetworkAccess=$WorkspacePublicNetworkAccess"
  )

  if ($EnableVnetInjection) {
    if ($null -eq $networkOutputs) {
      throw 'EnableVnetInjection was set but networking outputs were not available.'
    }

    $step1Args += @(
      'enableVnetInjection=true',
      "customVirtualNetworkId=$($networkOutputs.virtualNetworkId.value)",
      "customPublicSubnetName=$($networkOutputs.databricksPublicSubnetName.value)",
      "customPrivateSubnetName=$($networkOutputs.databricksPrivateSubnetName.value)",
      "enableNoPublicIp=$EnableNoPublicIp"
    )
  }

  Invoke-AzCli -AzCliArguments $step1Args

  # The workspace RP is sometimes eventually consistent; a short wait reduces flakiness in later queries
  Start-Sleep -Seconds 15
}

Write-Host "== Step 2: Deploy Key Vault + CMK keys ==" -ForegroundColor Green
if (Test-AzResourceExists -AzCliArguments @('keyvault','show','-g',$ResourceGroupName,'-n',$KeyVaultName,'-o','none')) {
  Write-Host "Key Vault '$KeyVaultName' already exists; skipping step 2." -ForegroundColor DarkGray
} else {
  $allowedSubnetIds = @()
  if (($AllowKeyVaultFromDatabricksSubnets -or $KeyVaultFirewallDefaultAction -eq 'Deny') -and $null -ne $networkOutputs) {
    $allowedSubnetIds += @(
      $networkOutputs.databricksPublicSubnetId.value,
      $networkOutputs.databricksPrivateSubnetId.value
    )
  }

  # IMPORTANT: passing JSON arrays inline is fragile on Windows because quote handling can strip the
  # double-quotes required for valid JSON strings. Use a temporary parameters file instead.
  $tmpParamsPath = Join-Path $env:TEMP ("bicep-kv-netparams-{0}-{1}.json" -f $ResourceGroupName, ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
  try {
    $tmpParams = @{
      '`$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
      contentVersion = '1.0.0.0'
      parameters     = @{
        allowedSubnetResourceIds = @{ value = $allowedSubnetIds }
        allowedIpRules           = @{ value = $KeyVaultAllowedIpRules }
      }
    }

    $tmpParams | ConvertTo-Json -Depth 20 | Set-Content -Path $tmpParamsPath -Encoding utf8

    $step2Args = @(
      'deployment','group','create',
      '-g',$ResourceGroupName,
      '-f',$Step2BicepPath,
      '-p',
      "location=$Location",
      "keyVaultName=$KeyVaultName",
      "managedServicesKeyName=$ManagedServicesKeyName",
      "managedDisksKeyName=$ManagedDisksKeyName",
      "publicNetworkAccess=$KeyVaultPublicNetworkAccess",
      "networkAclsBypass=$KeyVaultFirewallBypass",
      "networkAclsDefaultAction=$KeyVaultFirewallDefaultAction",
      "@$tmpParamsPath"
    )

    Invoke-AzCli -AzCliArguments $step2Args
  } finally {
    if (Test-Path $tmpParamsPath) {
      Remove-Item -Force -ErrorAction SilentlyContinue $tmpParamsPath
    }
  }
}

$kvPreflight = Invoke-AzCli -AzCliArguments @('keyvault','show','-g',$ResourceGroupName,'-n',$KeyVaultName) -CaptureJson
Assert-KeyVaultNetworkingSane -KeyVault $kvPreflight

if (-not $SkipStep3RoleAssignments) {
  Write-Host "== Step 3: Grant Key Vault Crypto Service Encryption User to required principals ==" -ForegroundColor Green

  $kv = Invoke-AzCli -AzCliArguments @('keyvault','show','-g',$ResourceGroupName,'-n',$KeyVaultName) -CaptureJson
  $kvId = $kv.id
  $managedServicesKeyScope = "$kvId/keys/$ManagedServicesKeyName"

  # Azure Databricks first-party service principal (Enterprise App) appId (from official docs)
  # https://learn.microsoft.com/en-us/azure/databricks/security/keys/cmk-managed-services-azure/customer-managed-key-managed-services-azure#step-1-set-up-a-key-vault
  # https://learn.microsoft.com/en-us/azure/databricks/security/keys/cmk-managed-services-azure/customer-managed-key-managed-services-azure#step-2-prepare-a-key
  $azureDatabricksAppId = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
  $azureDatabricksSpObjectId = Invoke-AzCli -AzCliArguments @('ad','sp','show','--id',$azureDatabricksAppId,'--query','id','-o','tsv')

  # Workspace storage identity (used by the Databricks RP to configure DBFS root encryption).
  $workspaceStoragePrincipalId = Invoke-AzCli -AzCliArguments @(
    'resource','show',
    '-g',$ResourceGroupName,
    '-n',$WorkspaceName,
    '--resource-type','Microsoft.Databricks/workspaces',
    '--query','properties.storageAccountIdentity.principalId',
    '-o','tsv'
  )

  if ([string]::IsNullOrWhiteSpace($workspaceStoragePrincipalId)) {
    Write-Warning "Workspace did not report properties.storageAccountIdentity.principalId yet. If step 1 just finished, retry step 3 in a few minutes."
  } else {
    # Databricks control-plane needs crypto access for managed services CMK.
    Invoke-AzCli -AzCliArguments @('role','assignment','create','--role','Key Vault Crypto Service Encryption User','--assignee-object-id',$azureDatabricksSpObjectId,'--assignee-principal-type','ServicePrincipal','--scope',$managedServicesKeyScope,'-o','none')

    # Grant the workspace storage identity crypto access at Key Vault scope.
    # Databricks uses this identity to apply DBFS root CMK on the workspace storage account.
    Invoke-AzCli -AzCliArguments @('role','assignment','create','--role','Key Vault Crypto Service Encryption User','--assignee-object-id',$workspaceStoragePrincipalId,'--assignee-principal-type','ServicePrincipal','--scope',$kvId,'-o','none')

    Write-Host "Granted KV crypto role to AzureDatabricks SP (services key scope) and workspace storage identity (vault scope)." -ForegroundColor DarkGreen
  }
}

Write-Host "== Step 4: Enable CMK on Databricks workspace (managed services + managed disks) ==" -ForegroundColor Green

$managedRgIdForUpdate = Get-ManagedRgId -WorkspaceName $WorkspaceName -ResourceGroupName $ResourceGroupName

Invoke-AzCli -AzCliArguments @(
  'deployment','group','create',
  '-g',$ResourceGroupName,
  '-f',$Step4BicepPath,
  '-p',
  "location=$Location",
  "managedResourceGroupId=$managedRgIdForUpdate",
  "workspaceName=$WorkspaceName",
  "keyVaultName=$KeyVaultName",
  "managedServicesKeyName=$ManagedServicesKeyName",
  "managedDisksKeyName=$ManagedDisksKeyName",
  "skuName=$SkuName"
)

if (-not $SkipStep5PostAssignments) {
  Write-Host "== Step 5: Grant KV crypto role to managed disk identities (post-enable) ==" -ForegroundColor Green

  $kvId = Invoke-AzCli -AzCliArguments @('keyvault','show','-g',$ResourceGroupName,'-n',$KeyVaultName,'--query','id','-o','tsv')
  $managedDisksKeyScope = "$kvId/keys/$ManagedDisksKeyName"

  $assignedPrincipals = @{}

  # Managed disk identity for the workspace (exposed on the workspace resource)
  $managedDiskIdentityPrincipalId = Invoke-AzCli -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces','--query','properties.managedDiskIdentity.principalId','-o','tsv')
  if (-not [string]::IsNullOrWhiteSpace($managedDiskIdentityPrincipalId)) {
    Invoke-AzCli -AzCliArguments @('role','assignment','create','--role','Key Vault Crypto Service Encryption User','--assignee-object-id',$managedDiskIdentityPrincipalId,'--assignee-principal-type','ServicePrincipal','--scope',$managedDisksKeyScope,'-o','none')
    $assignedPrincipals[$managedDiskIdentityPrincipalId.ToLowerInvariant()] = $true
  } else {
    Write-Warning "Workspace did not report properties.managedDiskIdentity.principalId yet. If step 4 just finished, retry step 5 in a few minutes."
  }

  # Disk Encryption Set created in the managed resource group (Databricks RP creates this)
  $desId = Invoke-AzCli -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces','--query','properties.diskEncryptionSetId','-o','tsv')
  if (-not [string]::IsNullOrWhiteSpace($desId)) {
    $desPrincipalId = Invoke-AzCli -AzCliArguments @('resource','show','--ids',$desId,'--query','identity.principalId','-o','tsv')
    if (-not [string]::IsNullOrWhiteSpace($desPrincipalId)) {
      $desPrincipalIdKey = $desPrincipalId.ToLowerInvariant()
      if ($assignedPrincipals.ContainsKey($desPrincipalIdKey)) {
        Write-Host "DES identity matches an already-assigned principal; skipping duplicate KV role assignment." -ForegroundColor DarkGray
      } else {
        Invoke-AzCli -AzCliArguments @('role','assignment','create','--role','Key Vault Crypto Service Encryption User','--assignee-object-id',$desPrincipalId,'--assignee-principal-type','ServicePrincipal','--scope',$managedDisksKeyScope,'-o','none')
      }
    } else {
      Write-Warning "Disk Encryption Set identity.principalId was empty; verify the DES has a system-assigned identity enabled."
    }
  } else {
    Write-Warning "Workspace did not report properties.diskEncryptionSetId yet. If step 4 just finished, retry step 5 in a few minutes."
  }
}

Write-Host "All steps complete." -ForegroundColor Green
