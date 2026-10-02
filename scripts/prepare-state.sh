#!/usr/bin/env bash
# One-time state-store exception: Azure CLI creates it OUTSIDE Terraform.
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
command -v az >/dev/null
export ECOM_STATE_SUBSCRIPTION ECOM_STATE_ACCOUNT
ECOM_STATE_SUBSCRIPTION=${ECOM_STATE_SUBSCRIPTION:-$(az account show --query id --output tsv)}
ECOM_STATE_ACCOUNT=${ECOM_STATE_ACCOUNT:-$(python3 -c 'import hashlib, os; print("stecomtf" + hashlib.sha256(os.environ["ECOM_STATE_SUBSCRIPTION"].encode()).hexdigest()[:14])')}
export ECOM_STATE_GROUP=${ECOM_STATE_GROUP:-rg-ecommerce-terraform-state}
export ECOM_STATE_LOCATION=${ECOM_STATE_LOCATION:-northeurope}
python3 - <<'PY'
import os, re
assert re.fullmatch(r'[a-z0-9]{3,24}', os.environ['ECOM_STATE_ACCOUNT']), 'Invalid account name.'
assert re.fullmatch(r'[a-zA-Z0-9_.()-]{1,90}', os.environ['ECOM_STATE_GROUP']), 'Invalid resource group.'
assert os.environ['ECOM_STATE_GROUP'].lower() not in ('rg-ecommerce-dev','rg-ecommerce-bootstrap')
if os.path.exists('bootstrap.auto.tfvars.json'):
    import json
    with open('bootstrap.auto.tfvars.json') as f: existing=json.load(f)
    for key, env_name in {
        'subscription_id':'ECOM_STATE_SUBSCRIPTION',
        'state_resource_group_name':'ECOM_STATE_GROUP',
        'state_storage_account_name':'ECOM_STATE_ACCOUNT',
        'location':'ECOM_STATE_LOCATION',
    }.items():
        assert existing.get(key) == os.environ[env_name], f'Existing configuration disagrees on {key}; review before any Azure mutation.'
PY
az account set --subscription "$ECOM_STATE_SUBSCRIPTION"
printf 'Preparing independent state storage in subscription %s, group %s, account %s.\n' \
  "$ECOM_STATE_SUBSCRIPTION" "$ECOM_STATE_GROUP" "$ECOM_STATE_ACCOUNT"
az provider register --namespace Microsoft.Storage --wait --output none
az group create --name "$ECOM_STATE_GROUP" --location "$ECOM_STATE_LOCATION" \
  --tags project=ECommerceStore lifecycle=external-state managedBy=Manual --output none
if az storage account show --name "$ECOM_STATE_ACCOUNT" --resource-group "$ECOM_STATE_GROUP" --output none 2>/dev/null; then
  echo 'Existing state account found; its settings will be checked without modification.'
else
  az storage account create --name "$ECOM_STATE_ACCOUNT" --resource-group "$ECOM_STATE_GROUP" \
    --location "$ECOM_STATE_LOCATION" --sku Standard_LRS --kind StorageV2 \
    --https-only true --min-tls-version TLS1_2 --allow-shared-key-access false \
    --allow-blob-public-access false --public-network-access Enabled \
    --tags project=ECommerceStore lifecycle=external-state managedBy=Manual --output none
fi
account_json=$(mktemp)
trap 'rm -f -- "$account_json"' EXIT
az storage account show --name "$ECOM_STATE_ACCOUNT" --resource-group "$ECOM_STATE_GROUP" >"$account_json"
python3 - "$account_json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: account=json.load(f)
assert account['kind'] == 'StorageV2' and account['sku']['name'] == 'Standard_LRS'
assert account['enableHttpsTrafficOnly'] and account['minimumTlsVersion'] == 'TLS1_2'
assert account.get('allowSharedKeyAccess') is False and account.get('allowBlobPublicAccess') is False
assert account.get('publicNetworkAccess') == 'Enabled', 'Hosted runners require authenticated public access in this MVP.'
PY
operator_id=$(az ad signed-in-user show --query id --output tsv)
account_scope="/subscriptions/$ECOM_STATE_SUBSCRIPTION/resourceGroups/$ECOM_STATE_GROUP/providers/Microsoft.Storage/storageAccounts/$ECOM_STATE_ACCOUNT"
role_count=$(az role assignment list --scope "$account_scope" \
  --query "length([?principalId=='$operator_id' && ends_with(roleDefinitionId, '/ba92f5b4-2d11-453d-a403-e96b0029c9fe')])" --output tsv)
if [[ $role_count == 0 ]]; then
  az role assignment create --assignee-object-id "$operator_id" --assignee-principal-type User \
    --role 'Storage Blob Data Contributor' --scope "$account_scope" --output none
fi
for container in bootstrap-state development-state; do
  if ! az storage container create --name "$container" --account-name "$ECOM_STATE_ACCOUNT" \
    --auth-mode login --public-access off --output none; then
    echo 'Container creation failed. RBAC may still be propagating; inspect the error and rerun after access is ready.' >&2
    exit 1
  fi
done
az lock create --name protect-independent-state --lock-type CanNotDelete \
  --resource-group "$ECOM_STATE_GROUP" --notes 'External state store; no application Terraform ownership.' --output none
python3 - <<'PY'
import json, os
values={
    'subscription_id': os.environ['ECOM_STATE_SUBSCRIPTION'],
    'state_resource_group_name': os.environ['ECOM_STATE_GROUP'],
    'state_storage_account_name': os.environ['ECOM_STATE_ACCOUNT'],
    'location': os.environ['ECOM_STATE_LOCATION'],
}
path='bootstrap.auto.tfvars.json'
if os.path.exists(path):
    with open(path) as f: existing=json.load(f)
    for key, value in values.items():
        assert existing.get(key) == value, f'Existing {path} disagrees on {key}; review it manually.'
else:
    with open(path,'x') as f: json.dump(values,f,indent=2)
with open('backend.hcl','w') as f:
    backend={
        'resource_group_name': values['state_resource_group_name'],
        'storage_account_name': values['state_storage_account_name'],
        'container_name': 'bootstrap-state',
        'key': 'ecommerce/bootstrap.tfstate',
    }
    for key, value in backend.items(): f.write(f'{key} = {json.dumps(value)}\n')
PY
echo 'Independent state store ready. Review bootstrap.auto.tfvars.json, then run bash scripts/init-backend.sh.'
