[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [string] $SubscriptionId,

  [Parameter(Mandatory)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory)]
  [string] $WorkspaceName,

  [string] $ManagedResourceGroupName = "$WorkspaceName-managed",

  [switch] $Wait
)

$ErrorActionPreference = 'Stop'
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

function Test-RgExists {
  param([Parameter(Mandatory)][string] $Name)

  try {
    Invoke-AzCli -AzCliArguments @('group','show','-n',$Name,'-o','none') | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Wait-ForDeletion {
  param([Parameter(Mandatory)][string] $Name)

  $maxMinutes = 60
  $start = Get-Date
  while ((Get-Date) -lt $start.AddMinutes($maxMinutes)) {
    if (-not (Test-RgExists -Name $Name)) {
      Write-Host "Resource group '$Name' is deleted." -ForegroundColor Green
      return
    }
    Write-Host "Waiting for resource group '$Name' to delete..." -ForegroundColor Yellow
    Start-Sleep -Seconds 20
  }

  Write-Warning "Timed out waiting for resource group '$Name' deletion. It may still be deleting in the background."
}

Write-Host "== Cleanup: Azure Databricks CMK deployment ==" -ForegroundColor Green
Invoke-AzCli -AzCliArguments @('account','set','--subscription',$SubscriptionId) | Out-Null

Write-Host "Will delete resource groups:" -ForegroundColor Cyan
Write-Host "- $ResourceGroupName" -ForegroundColor Cyan
Write-Host "- $ManagedResourceGroupName" -ForegroundColor Cyan
Write-Host "Note: Key Vault purge protection was enabled; deleting the vault will soft-delete it and you may NOT be able to immediately reuse the same Key Vault name." -ForegroundColor Yellow

if ($PSCmdlet.ShouldProcess("$ResourceGroupName and $ManagedResourceGroupName", 'Delete resource groups')) {
  if (Test-RgExists -Name $ResourceGroupName) {
    Write-Host "Deleting '$ResourceGroupName'..." -ForegroundColor Green
    Invoke-AzCli -AzCliArguments @('group','delete','-n',$ResourceGroupName,'--yes','--no-wait') | Out-Null
  } else {
    Write-Host "Resource group '$ResourceGroupName' not found; skipping." -ForegroundColor DarkGray
  }

  if (Test-RgExists -Name $ManagedResourceGroupName) {
    Write-Host "Deleting '$ManagedResourceGroupName' (Databricks managed RG)..." -ForegroundColor Green
    try {
      Invoke-AzCli -AzCliArguments @('group','delete','-n',$ManagedResourceGroupName,'--yes','--no-wait') | Out-Null
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match 'DenyAssignmentAuthorizationFailed') {
        Write-Warning "Managed RG deletion blocked by Databricks deny assignment. This usually clears after the workspace (in '$ResourceGroupName') is fully deleted. Will retry if -Wait is set."
      } else {
        throw
      }
    }
  } else {
    Write-Host "Managed resource group '$ManagedResourceGroupName' not found; skipping." -ForegroundColor DarkGray
  }
}

if ($Wait) {
  # First wait for the workspace RG to delete; that removes Databricks deny assignments.
  Wait-ForDeletion -Name $ResourceGroupName

  # Retry managed RG deletion after the workspace RG is gone.
  if (Test-RgExists -Name $ManagedResourceGroupName) {
    Write-Host "Retrying deletion of managed resource group '$ManagedResourceGroupName'..." -ForegroundColor Green
    try {
      Invoke-AzCli -AzCliArguments @('group','delete','-n',$ManagedResourceGroupName,'--yes','--no-wait') | Out-Null
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match 'DenyAssignmentAuthorizationFailed') {
        Write-Warning "Still blocked by deny assignment. If the workspace deletion is complete, you may need a few more minutes for deny assignments to clear, then re-run cleanup for the managed RG."
      } else {
        throw
      }
    }
  }

  Wait-ForDeletion -Name $ManagedResourceGroupName
}

Write-Host "Cleanup requested; deletions may still be in progress." -ForegroundColor Green
