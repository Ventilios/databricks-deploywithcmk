[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $SubscriptionId,

  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $WorkspaceName,

  [Parameter(Mandatory)]
  [string] $KeyVaultName,

  [string] $ManagedServicesKeyName = 'dbx-managed-services',

  [string] $ManagedDisksKeyName = 'dbx-managed-disks',

  [string] $ManagedResourceGroupName = "$WorkspaceName-managed"
)

$ErrorActionPreference = 'Stop'

# Prevent native stderr output from being treated as terminating errors.
$global:PSNativeCommandUseErrorActionPreference = $false

function Invoke-AzCli {
  param(
    [Parameter(Mandatory)]
    [string[]] $AzCliArguments,

    [switch] $CaptureJson
  )

  $finalArgs = @($AzCliArguments)
  if (-not ($finalArgs -contains '--only-show-errors')) {
    $finalArgs += '--only-show-errors'
  }
  if ($CaptureJson -and -not ($finalArgs -contains '-o' -or $finalArgs -contains '--output')) {
    $finalArgs += @('-o', 'json')
  }

  $cmdDisplay = ($finalArgs | ForEach-Object {
      if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
  Write-Host "az $cmdDisplay" -ForegroundColor DarkGray

  $out = & az @finalArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI failed (exit $LASTEXITCODE): az $cmdDisplay`n$out"
  }

  if ($CaptureJson) {
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    return $out | ConvertFrom-Json
  }

  return ($out | Out-String).Trim()
}

function Assert-True {
  param(
    [Parameter(Mandatory)][object] $Condition,
    [Parameter(Mandatory)][string] $Message
  )

  $isTrue = $false

  if ($null -eq $Condition) {
    $isTrue = $false
  } elseif ($Condition -is [bool]) {
    $isTrue = [bool]$Condition
  } elseif ($Condition -is [string]) {
    $isTrue = -not [string]::IsNullOrWhiteSpace($Condition)
  } elseif ($Condition -is [int] -or $Condition -is [long]) {
    $isTrue = ([long]$Condition -ne 0)
  } else {
    # Non-null objects are considered truthy.
    $isTrue = $true
  }

  if (-not $isTrue) {
    throw "VERIFY FAILED: $Message"
  }
}

function Write-Check {
  param(
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][scriptblock] $Block
  )

  Write-Host "-- $Name" -ForegroundColor Cyan
  & $Block
  Write-Host "   OK" -ForegroundColor Green
}

function Get-RgNameFromId {
  param([Parameter(Mandatory)][string] $ResourceId)

  $parts = $ResourceId -split '/'
  $idx = [Array]::IndexOf($parts, 'resourceGroups')
  if ($idx -lt 0 -or ($idx + 1) -ge $parts.Length) {
    throw "Could not parse resource group name from: $ResourceId"
  }
  return $parts[$idx + 1]
}

Write-Host "== Verification: Databricks CMK deployment ==" -ForegroundColor Green

$cryptoRole = 'Key Vault Crypto Service Encryption User'
$roleCountQuery = "[?roleDefinitionName=='$cryptoRole'] | length(@)"

Invoke-AzCli -AzCliArguments @('account','set','--subscription',$SubscriptionId) | Out-Null

Write-Check -Name 'Workspace exists and CMK fields present' -Block {
  $ws = Invoke-AzCli -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces') -CaptureJson

  Assert-True ($null -ne $ws) 'Workspace resource not found.'
  Assert-True ($ws.properties.managedResourceGroupId) 'Workspace.properties.managedResourceGroupId missing.'

  # Validate encryption objects are configured
  Assert-True ($ws.properties.encryption.entities.managedServices.keyVaultProperties.keyVaultUri) 'Managed services CMK keyVaultUri missing.'
  Assert-True ($ws.properties.encryption.entities.managedServices.keyVaultProperties.keyName) 'Managed services CMK keyName missing.'
  Assert-True ($ws.properties.encryption.entities.managedDisk.keyVaultProperties.keyVaultUri) 'Managed disks CMK keyVaultUri missing.'
  Assert-True ($ws.properties.encryption.entities.managedDisk.keyVaultProperties.keyName) 'Managed disks CMK keyName missing.'

  # Helpful outputs
  Write-Host "   managedResourceGroupId: $($ws.properties.managedResourceGroupId)" -ForegroundColor DarkGray
  Write-Host "   diskEncryptionSetId:   $($ws.properties.diskEncryptionSetId)" -ForegroundColor DarkGray
}

Write-Check -Name 'Key Vault and both keys exist' -Block {
  $kvId = Invoke-AzCli -AzCliArguments @('keyvault','show','-g',$ResourceGroupName,'-n',$KeyVaultName,'--query','id','-o','tsv')
  Assert-True (-not [string]::IsNullOrWhiteSpace($kvId)) 'Key Vault id not found.'

  # Prefer management-plane checks so callers don't need Key Vault data-plane read permissions.
  $servicesKeyId = "$kvId/keys/$ManagedServicesKeyName"
  $disksKeyId = "$kvId/keys/$ManagedDisksKeyName"

  $sKeyArm = $null
  $dKeyArm = $null
  try {
    $sKeyArm = Invoke-AzCli -AzCliArguments @('resource','show','--ids',$servicesKeyId) -CaptureJson
    $dKeyArm = Invoke-AzCli -AzCliArguments @('resource','show','--ids',$disksKeyId) -CaptureJson
  } catch {
    # Fallback to data-plane checks if the caller has permissions.
    try {
      $sKeyDp = Invoke-AzCli -AzCliArguments @('keyvault','key','show','--vault-name',$KeyVaultName,'-n',$ManagedServicesKeyName) -CaptureJson
      $dKeyDp = Invoke-AzCli -AzCliArguments @('keyvault','key','show','--vault-name',$KeyVaultName,'-n',$ManagedDisksKeyName) -CaptureJson

      Assert-True ($sKeyDp.key.kid) 'Managed services key not found.'
      Assert-True ($dKeyDp.key.kid) 'Managed disks key not found.'
      Write-Host "   (validated keys via Key Vault data-plane)" -ForegroundColor DarkGray
      return
    } catch {
      throw "VERIFY FAILED: Unable to validate Key Vault keys. You may need management-plane read access on the key resources, or data-plane read access (for example, 'Key Vault Crypto Officer') on the vault. Underlying error: $($_.Exception.Message)"
    }
  }

  Assert-True ($sKeyArm.id) 'Managed services key not found (ARM).' 
  Assert-True ($dKeyArm.id) 'Managed disks key not found (ARM).' 

  Write-Host "   key scope (services): $kvId/keys/$ManagedServicesKeyName" -ForegroundColor DarkGray
  Write-Host "   key scope (disks):    $kvId/keys/$ManagedDisksKeyName" -ForegroundColor DarkGray
}

Write-Check -Name 'DBFS root storage encryption uses Key Vault (CMK)' -Block {
  $ws = Invoke-AzCli -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces') -CaptureJson

  # Databricks configures DBFS root CMK via workspace parameters.encryption.
  Assert-True ($ws.properties.parameters.encryption.value.keyvaulturi) 'Workspace parameters.encryption.value.keyvaulturi missing.'
  Assert-True ($ws.properties.parameters.encryption.value.KeyName -eq $ManagedServicesKeyName) "Workspace parameters.encryption.value.KeyName is '$($ws.properties.parameters.encryption.value.KeyName)' (expected $ManagedServicesKeyName)."
  Assert-True ($ws.properties.parameters.encryption.value.keyversion) 'Workspace parameters.encryption.value.keyversion missing.'

  # Best-effort validation that the underlying workspace storage account shows Key Vault CMK.
  try {
    $managedRgName = Get-RgNameFromId -ResourceId $ws.properties.managedResourceGroupId
    $storage = Invoke-AzCli -AzCliArguments @('storage','account','list','-g',$managedRgName,'--query','[?identity.principalId!=null] | [0]') -CaptureJson
    if ($storage -and $storage.name) {
      $enc = Invoke-AzCli -AzCliArguments @('storage','account','show','-g',$managedRgName,'-n',$storage.name,'--query','encryption') -CaptureJson
      Write-Host "   storage '$($storage.name)' keySource: $($enc.keySource)" -ForegroundColor DarkGray
    }
  } catch {
    Write-Host "   (skipped storage account check: $($_.Exception.Message))" -ForegroundColor DarkYellow
  }
}

Write-Check -Name 'Role assignments: AzureDatabricks SP (services key) + workspace storage identity (vault)' -Block {
  $kvId = Invoke-AzCli -AzCliArguments @('keyvault','show','-g',$ResourceGroupName,'-n',$KeyVaultName,'--query','id','-o','tsv')
  $servicesScope = "$kvId/keys/$ManagedServicesKeyName"

  # Azure Databricks first-party SP (appId from docs)
  $azureDatabricksAppId = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
  $azureDatabricksSpObjectId = Invoke-AzCli -AzCliArguments @('ad','sp','show','--id',$azureDatabricksAppId,'--query','id','-o','tsv')

  $assign1 = Invoke-AzCli -AzCliArguments @('role','assignment','list','--assignee-object-id',$azureDatabricksSpObjectId,'--scope',$servicesScope,'--query',$roleCountQuery,'-o','tsv')
  Assert-True ([int]$assign1 -ge 1) 'Missing Crypto Service Encryption User for AzureDatabricks SP on services key.'

  # Workspace storage identity for DBFS root CMK should have vault-scope crypto access.
  $ws = Invoke-AzCli -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces') -CaptureJson
  Assert-True ($ws.properties.storageAccountIdentity.principalId) 'Workspace storageAccountIdentity.principalId missing.'

  $assign2 = Invoke-AzCli -AzCliArguments @('role','assignment','list','--assignee-object-id',$ws.properties.storageAccountIdentity.principalId,'--scope',$kvId,'--query',$roleCountQuery,'-o','tsv')
  Assert-True ([int]$assign2 -ge 1) 'Missing Crypto Service Encryption User for workspace storage identity on Key Vault scope.'
}

Write-Check -Name 'Role assignments: managedDiskIdentity + DES identity on disks key' -Block {
  $kvId = Invoke-AzCli -AzCliArguments @('keyvault','show','-g',$ResourceGroupName,'-n',$KeyVaultName,'--query','id','-o','tsv')
  $disksScope = "$kvId/keys/$ManagedDisksKeyName"

  $ws = Invoke-AzCli -AzCliArguments @('resource','show','-g',$ResourceGroupName,'-n',$WorkspaceName,'--resource-type','Microsoft.Databricks/workspaces') -CaptureJson

  Assert-True ($ws.properties.managedDiskIdentity.principalId) 'Workspace managedDiskIdentity.principalId missing.'
  $assign1 = Invoke-AzCli -AzCliArguments @('role','assignment','list','--assignee-object-id',$ws.properties.managedDiskIdentity.principalId,'--scope',$disksScope,'--query',$roleCountQuery,'-o','tsv')
  Assert-True ([int]$assign1 -ge 1) 'Missing Crypto Service Encryption User for managedDiskIdentity on disks key.'

  Assert-True ($ws.properties.diskEncryptionSetId) 'Workspace diskEncryptionSetId missing (DES not created yet).'
  $desPrincipalId = Invoke-AzCli -AzCliArguments @('resource','show','--ids',$ws.properties.diskEncryptionSetId,'--query','identity.principalId','-o','tsv')
  Assert-True (-not [string]::IsNullOrWhiteSpace($desPrincipalId)) 'DES identity.principalId missing.'

  $assign2 = Invoke-AzCli -AzCliArguments @('role','assignment','list','--assignee-object-id',$desPrincipalId,'--scope',$disksScope,'--query',$roleCountQuery,'-o','tsv')
  Assert-True ([int]$assign2 -ge 1) 'Missing Crypto Service Encryption User for DES identity on disks key.'
}

Write-Host "All verification checks passed." -ForegroundColor Green
