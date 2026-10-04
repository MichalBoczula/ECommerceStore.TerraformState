#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ -f bootstrap.auto.tfvars.json && -f backend.hcl ]] || { echo 'Prepare the independent state store/configuration first.' >&2; exit 1; }
command -v terraform >/dev/null
command -v az >/dev/null
subscription=$(python3 -c 'import json; print(json.load(open("bootstrap.auto.tfvars.json"))["subscription_id"])' | tr -d '\r')
az account set --subscription "$subscription"
terraform init -input=false -lockfile=readonly -backend-config=backend.hcl
