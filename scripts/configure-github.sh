#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
repo=MichalBoczula/ECommerceStore.Infrastructure
command -v terraform >/dev/null
command -v gh >/dev/null
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
terraform output -json development_github_variables >"$temp_dir/variables.json"

# Keep existing protection settings; add a custom branch restriction only
# when none exists. Never remove an existing reviewer/approval configuration.
if ! gh api "repos/$repo/environments/development" >"$temp_dir/environment.json" 2>"$temp_dir/environment-error.log"; then
  [[ $(<"$temp_dir/environment-error.log") == *'HTTP 404'* ]] || { echo 'Cannot read the GitHub environment. Check repository administration access.' >&2; exit 1; }
  gh api --method PUT "repos/$repo/environments/development" \
    -F 'deployment_branch_policy[protected_branches]=false' \
    -F 'deployment_branch_policy[custom_branch_policies]=true' >"$temp_dir/environment.json"
fi
policy=$(python3 - "$temp_dir/environment.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: p = json.load(f).get('deployment_branch_policy')
print('custom' if p and p.get('custom_branch_policies') else ('protected' if p and p.get('protected_branches') else 'none'))
PY
)
policy=${policy%$'\r'}
if [[ $policy == none ]]; then
  echo 'Existing environment has no branch policy. Set selected deployment branches to main in GitHub Settings, preserving its other protection rules, then rerun.' >&2
  exit 1
fi
if [[ $policy == protected ]]; then
  echo 'Existing protected-branch policy retained. Verify that main is protected and permitted.'
else
  gh api "repos/$repo/environments/development/deployment-branch-policies" \
    --paginate --slurp >"$temp_dir/branches.json"
  if ! python3 - "$temp_dir/branches.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: pages = json.load(f)
names = {(p['name'], p.get('type', 'branch')) for page in pages for p in page['branch_policies']}
if names - {('main', 'branch')}:
    sys.exit('Existing extra deployment branches/tags found. Review them before OIDC validation; this script does not silently delete rules.')
sys.exit(0 if ('main', 'branch') in names else 1)
PY
  then
    # Reject extra rules separately instead of treating them as a missing main.
    python3 - "$temp_dir/branches.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: pages=json.load(f)
assert not any(p['name'] != 'main' or p.get('type','branch') != 'branch' for page in pages for p in page['branch_policies']), 'Review existing branch rules manually.'
PY
    gh api --method POST "repos/$repo/environments/development/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
  fi
fi
python3 - "$temp_dir/variables.json" "$temp_dir/variables.tsv" <<'PY'
import json, sys
with open(sys.argv[1]) as f: values = json.load(f)
assert set(values) == {'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'TFSTATE_RESOURCE_GROUP', 'TFSTATE_STORAGE_ACCOUNT', 'TFSTATE_CONTAINER'}
with open(sys.argv[2], 'w', newline='\n') as f:
    for name, value in values.items():
        assert '\n' not in value and '\r' not in value and '\t' not in value
        f.write(name + '\t' + value + '\n')
PY
while IFS=$'\t' read -r name value; do
  case "$name" in
    AZURE_CLIENT_ID|AZURE_TENANT_ID|AZURE_SUBSCRIPTION_ID)
      printf '%s' "$value" | gh secret set "$name" --repo "$repo" --env development
      ;;
    *)
      gh variable set "$name" --repo "$repo" --env development --body "$value"
      ;;
  esac
done <"$temp_dir/variables.tsv"
echo 'Configured development environment. Run Verify development backend on main after its PR is merged.'
