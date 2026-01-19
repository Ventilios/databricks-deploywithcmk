# Azure Databricks + CMK (managed services + managed disks + DBFS root) with Bicep

This repo deploys Azure Databricks and enables Customer-Managed Keys (CMK) in multiple steps:

0.5. (Optional) Deploy a VNet + subnets for VNet injection
1. Deploy a basic Databricks workspace
2. Deploy Key Vault and create CMK keys
3. Grant **Key Vault Crypto Service Encryption User** to:
  - AzureDatabricks service principal (managed services key scope)
  - workspace storage identity (Key Vault scope, required for DBFS root CMK)
4. Enable CMK on the Databricks workspace (managed services + managed disks + DBFS root)
5. After enabling, grant **Key Vault Crypto Service Encryption User** to the Databricks managed disk identities (managedDiskIdentity + Disk Encryption Set)

## Files

- [infra/steps/00-networking.bicep](infra/steps/00-networking.bicep)
- [infra/steps/01-databricks-basic.bicep](infra/steps/01-databricks-basic.bicep)
- [infra/steps/02-keyvault-keys.bicep](infra/steps/02-keyvault-keys.bicep)
- [infra/steps/04-enable-dbx-cmk.bicep](infra/steps/04-enable-dbx-cmk.bicep)
- [deploy.ps1](deploy.ps1)
- [verify.ps1](verify.ps1)
- [cleanup.ps1](cleanup.ps1)

## Prerequisites

- Azure CLI (`az`) logged in: `az login`
- Access to create Resource Groups, Databricks, Key Vault, and role assignments
- The Key Vault must be in the same tenant as the Databricks workspace
- DBFS root CMK is a Premium feature in Azure Databricks (this repo assumes `-SkuName premium`)
- Key Vault soft delete + purge protection are required for Databricks CMK scenarios

## Deploy

The examples below assume your current directory is the repo root. If you are *not* in the repo root, use the **absolute** `-File` examples shown under each section.
This repo is designed around two supported scenarios:

1) **Public (simple)**: no VNet injection, Key Vault is reachable via public endpoint.
2) **VNet injection + firewall**: Databricks uses VNet injection (no public IPs for compute) and Key Vault stays on the public endpoint (`publicNetworkAccess=Enabled`) but is locked down with firewall rules (`defaultAction=Deny`) while allowing the Databricks subnets (might not be needed to lock further down) and allow Azure Services (`bypass=AzureServices`).

```powershell
./deploy.ps1 \
  -SubscriptionId "<sub-guid>" \
  -Location "<region>" \
  -ResourceGroupName "rg-dbx-cmk" \
  -WorkspaceName "adb-cmk-demo-001" \
  -KeyVaultName "kvdbxcmkdemo001" \
  -SkuName "premium"
```

Absolute-path equivalent (copy/paste safe from any folder):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo-root>\deploy.ps1" \
  -SubscriptionId "<sub-guid>" \
  -Location "<region>" \
  -ResourceGroupName "rg-dbx-cmk" \
  -WorkspaceName "adb-cmk-demo-001" \
  -KeyVaultName "kvdbxcmkdemo001" \
  -SkuName "premium"
```

### Scenario 1: Public (quick)

This creates a public deployment with unique names, runs `verify.ps1`, and prints the cleanup command.

```powershell
./infra/examples/smoke.public.ps1 \
  -SubscriptionId "<sub-guid>" \
  -Location "<region>"
```

Absolute-path equivalent:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo-root>\infra\examples\smoke.public.ps1" \
  -SubscriptionId "<sub-guid>" \
  -Location "<region>"
```

### Scenario 2: Secure networking (VNet injection + Key Vault firewall)

This creates a VNet + delegated Databricks subnets (optional NAT), deploys the workspace with VNet injection and `enableNoPublicIp=true`, and configures Key Vault firewall `Deny` while allowing the Databricks subnets.

```powershell
./infra/examples/smoke.secure.ps1 \
  -SubscriptionId "<sub-guid>" \
  -Location "<region>"
```

Absolute-path equivalent:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo-root>\infra\examples\smoke.secure.ps1" \
  -SubscriptionId "<sub-guid>" \
  -Location "<region>"
```

If you set `-KeyVaultPublicNetworkAccess Disabled`, the deployment will stop because Databricks CMK won’t be able to reach Key Vault.

> Note: Fully-private CMK scenarios can be tricky because Databricks (control plane / managed resources) must still be able to reach Key Vault. Use the preflight checks in `deploy.ps1` and validate with `verify.ps1`.

Optional:

- Skip step 3 role assignments: add `-SkipStep3RoleAssignments`
- Skip step 5 post-enable assignments: add `-SkipStep5PostAssignments`

Example invocation script: [infra/examples/deploy.example.ps1](infra/examples/deploy.example.ps1)

To automatically clean up afterwards, add `-Cleanup -Wait` to either smoke script.

Key names (optional overrides):

- Managed services key: `-ManagedServicesKeyName` (default: `dbx-managed-services`)
- Managed disks key: `-ManagedDisksKeyName` (default: `dbx-managed-disks`)

## Verify

```powershell
./verify.ps1 \
  -SubscriptionId "<sub-guid>" \
  -ResourceGroupName "rg-dbx-cmk" \
  -WorkspaceName "adb-cmk-demo-001" \
  -KeyVaultName "kvdbxcmkdemo001"
```

Absolute-path equivalent:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo-root>\verify.ps1" \
  -SubscriptionId "<sub-guid>" \
  -ResourceGroupName "rg-dbx-cmk" \
  -WorkspaceName "adb-cmk-demo-001" \
  -KeyVaultName "kvdbxcmkdemo001"
```

Example verification script: [infra/examples/verify.example.ps1](infra/examples/verify.example.ps1)

## Cleanup (fresh redeploy)

```powershell
./cleanup.ps1 \
  -SubscriptionId "<sub-guid>" \
  -ResourceGroupName "rg-dbx-cmk" \
  -WorkspaceName "adb-cmk-demo-001" \
  -Wait
```

Absolute-path equivalent:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo-root>\cleanup.ps1" \
  -SubscriptionId "<sub-guid>" \
  -ResourceGroupName "rg-dbx-cmk" \
  -WorkspaceName "adb-cmk-demo-001" \
  -Wait
```

Note: this deletes both the deployment RG and the Databricks managed resource group (`<workspace>-managed`).

Note: the Key Vault is created with purge protection enabled; deleting it will soft-delete it and you may not be able to immediately reuse the same Key Vault name.

## Notes / Debugging tips

- Role assignments can take a few minutes to propagate. If compute won’t start after enabling CMK for disks, re-run step 5.
- Step 4 requires `properties.managedResourceGroupId` to be provided again on update; the script queries it via `az resource show`.
- If your setup uses a *custom* storage account (not the managed one), adjust step 3 in [deploy.ps1](deploy.ps1) to grant the role to that storage account’s managed identity.
- The script scopes Key Vault role assignments to the specific key resources (least privilege), not the whole vault.

Repo hygiene:

- The `infra/steps/*.json` ARM templates are generated build artifacts. Use the `*.bicep` sources.

DBFS root (default DBFS) encryption:

- DBFS root CMK is configured via the Databricks workspace update (see [infra/steps/04-enable-dbx-cmk.bicep](infra/steps/04-enable-dbx-cmk.bicep)), using the workspace custom parameter `properties.parameters.encryption`.
- This lets the Databricks RP update the workspace storage account inside the managed resource group (avoids Databricks deny-assignment issues that block direct `Microsoft.Storage/storageAccounts/write`).
- Step 3 grants `Key Vault Crypto Service Encryption User` to `properties.storageAccountIdentity.principalId` on the Key Vault scope, as required for DBFS root CMK.

## References

- Azure Databricks CMK for managed services: https://learn.microsoft.com/azure/databricks/security/keys/cmk-managed-services-azure/
- Azure Databricks CMK for managed disks: https://learn.microsoft.com/azure/databricks/security/keys/cmk-managed-disks-azure/
- Azure Databricks CMK for DBFS root: https://learn.microsoft.com/azure/databricks/security/keys/customer-managed-keys-dbfs/
