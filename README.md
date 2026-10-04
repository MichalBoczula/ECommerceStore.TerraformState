# ECommerceStore.TerraformState

Persistent deployment foundation for the e-commerce portfolio. The independent
Azure state account and containers are created once **outside Terraform**.
This repository does not declare, import or destroy those storage resources.
Application infrastructure remains in ECommerceStore.Infrastructure; portfolio
will use its own root, identity, resource group and state in a later task.

## Current scope

- `scripts/prepare-state.sh`: one-time Azure CLI setup of independent state
  storage (the explicit exception to Terraform-managed infrastructure).
- Terraform: persistent deployment identity, GitHub OIDC federation, scoped
  access assignments and the retained development resource group.
- `scripts/configure-github.sh`: writes Azure ID environment secrets and backend
  environment variables from Terraform outputs to the existing development infrastructure repo.
- CI: format, shell checks, provider validation and mocked Terraform plans.

No application, database, private endpoint, gateway or dedicated compute is
created by this repository. Azure setup has not yet been executed.

## Ownership and teardown

| Item | Owner | Survives application Destroy |
| --- | --- | --- |
| State RG/account/containers | One-time external setup | Yes |
| `rg-ecommerce-bootstrap` and deployment identity | This repo's persistent state | Yes |
| Empty `rg-ecommerce-dev` and scoped access | This repo's persistent state | Yes |
| Application resources and data | Development application state | No |

One Azure subscription is used. Retaining the empty development group preserves
RG-scoped access after teardown. Application Terraform must read that existing
resource group as data, never declare/import it. There is no inherited lock on
it, because that would block deleting its children. The custom deployment role
excludes group deletion and access/lock-management writes.

The state account is a Terraform **data source** here: Terraform reads its ID
for scoped RBAC without owning its lifecycle. It must be in its own group,
separate from both Terraform-managed groups. The new deployment identity gets
Reader on the state account and Storage Blob Data Contributor only on the
`development-state` container. It receives no subscription-wide management role
and no access to the `bootstrap-state` container.

The bootstrap operator needs existing subscription Owner or equivalent rights
to create the identity, custom role and role assignments. Access grants are
additive: do not add subscription-wide Contributor/Owner to the new deployment
identity. App-role delegation defaults to disabled; D/7 can explicitly enable
conditional, RG-scoped grants of Blob Data Contributor/Key Vault Secrets User
for application service principals, excluding self-grants.

## First setup on your machine

Use Bash (for example WSL), Terraform **1.16.5**, Azure CLI and GitHub CLI.
Credentials stay on your machine; do not send tokens, keys or state in chat.

On Windows, use the same Bash environment for Azure login and the setup scripts
(for example, WSL with its own Azure CLI installation). Shell scripts must use
LF line endings; `.gitattributes` enforces this for new checkouts. If an existing
checkout reports `set: pipefail: invalid option name`, convert `scripts/*.sh`
from CRLF to LF in your editor (VS Code: click CRLF, select LF, save), then retry.

```bash
az login
az account list --output table
az account set --subscription YOUR_SUBSCRIPTION_ID
gh auth login

bash scripts/prepare-state.sh
# Review the generated subscription, region and account settings.
bash scripts/init-backend.sh
terraform validate
terraform test -test-directory=tests
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
bash scripts/configure-github.sh
```

`prepare-state.sh` defaults to North Europe and a deterministic globally unique
account name derived from your selected subscription. You can set
`ECOM_STATE_ACCOUNT`, `ECOM_STATE_GROUP`, `ECOM_STATE_LOCATION` and
`ECOM_STATE_SUBSCRIPTION` before running it. Review the target subscription first.
If an account already exists in the chosen group, it is checked without changing
its settings. A global name collision requires choosing a different name.

The external account uses Standard LRS, HTTPS/TLS 1.2, private containers,
Shared Key authorization disabled and authenticated public network access so
GitHub-hosted runners need no private endpoint. The operator receives state-data
access and the external group gets a CanNotDelete lock. Role propagation may
delay container creation; inspect the CLI error and rerun once access is ready.
The script creates no Terraform resources or local Terraform state.

The setup writes ignored `bootstrap.auto.tfvars.json` and `backend.hcl`.
`init-backend.sh` initializes the already-existing Azure backend directly:
there is no local-to-remote bootstrap migration. Keep state/plans/credentials
out of GitHub; only code and non-secret configuration examples are committed.

If you create storage manually in Azure Portal, create both private containers,
grant the operator Blob Data Contributor, disable Shared Key/public blobs and
prepare equivalent variable/backend files. Then start at `init-backend.sh`.

## State layout

| Container | Blob key | Purpose |
| --- | --- | --- |
| `bootstrap-state` | `ecommerce/bootstrap.tfstate` | Persistent identity and access foundation |
| `development-state` | `ecommerce/development.tfstate` | Disposable development resources |

Terraform writes the active state to Azure and uses Blob leases for locking.
GitHub stores the code and workflow history. These are separate responsibilities.
Blob versioning, soft-delete retention and a tested recovery procedure are a
later backup task; they are not enabled by this initial script. A state version
restore is recovery, not a normal infrastructure rollback. Normal rollback means
reverting code and planning/applying against the current state.

## Configure and verify development

The GitHub helper creates the `development` environment if absent, restricts a
new environment to `main` and reads the six configuration values consumed by
D/1 and D/2 from Terraform outputs. It stores `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`
and `AZURE_SUBSCRIPTION_ID` as environment secrets, and the three `TFSTATE_*`
settings as environment variables. This preserves the user's preference to hide
Azure identifiers in public workflow logs; authentication remains passwordless
OIDC, without a client secret. It preserves existing protection rules and stops for
conflicting branch policies. No required-reviewer gate is added. It requires
repository administration access.

For browser setup, open Infrastructure Settings > Environments > development.
Add the three Azure IDs under **Environment secrets** and the three backend
settings under **Environment variables**, one name/value at a time. Copy raw
values from `terraform output -json development_github_variables`; do not paste
the whole JSON. The output name is retained for compatibility and contains both
categories. Remove any old Azure ID variables if you previously configured them
there. This helper adds secrets but does not delete existing variables.

OIDC subject:
`repo:MichalBoczula@38834900/ECommerceStore.Infrastructure@1401844464:environment:development`.
Issuer: `https://token.actions.githubusercontent.com`.
Audience: `api://AzureADTokenExchange`.

The subject includes GitHub's immutable owner ID and repository ID. It matches
the subject emitted by this repository's workflow, confirmed on 2026-10-04.
For `AADSTS700213`, compare the logged issuer, subject and audience with the
credential before changing permissions. New GitHub repositories use the
immutable format; the older name-only subject does not match this repository.
Apply subject corrections from this foundation root against its existing state.
AzureRM 5.8.0 can update the credential subject in place. In PowerShell:

```powershell
git pull --ff-only
terraform validate
terraform test "-test-directory=tests"
terraform plan "-out=bootstrap.tfplan"
# Review the plan: only the federated credential subject should change.
terraform apply "bootstrap.tfplan"
```

Then rerun **Verify development backend**. No secret changes are required for a
subject-only correction.

Reference: [GitHub OIDC subject formats](https://docs.github.com/en/actions/reference/security/oidc).

After setup, run **Verify development backend** on `main` in Infrastructure.
It verifies OIDC, remote init, locked planning, no-change apply and state read,
rejecting managed-resource changes. Then run Destroy on the empty state to
verify the retained group and independent state account survive.

No live Azure execution has run yet. Empty-state checks do not prove resource
permissions for every future service. D/18 must prove real apply/destroy/reapply
and inspect ACA managed groups, retained backups and remaining billing.

## Maintenance

Terraform and AzureRM are pinned and `.terraform.lock.hcl` is committed.
Run normal `terraform plan`/`apply` for foundation updates against the persistent
remote state. There is no bootstrap Destroy button or automatic Azure deploy
on push. Persistent resources have `prevent_destroy`.

Existing infrastructure requires explicit, reviewed imports; never start from
empty state after an interrupted apply. Preserve provider/module configuration
and required variables, do not force-unlock an active operation, and reconcile
any untracked resources. Provider registration for ManagedIdentity is managed
here by Terraform; storage registration belongs to the external setup exception.
Future application providers require deliberate foundation updates.

Portfolio state/container/group/identity are added under P/2, without granting
the development identity access to them. The external state account remains
independent of both deployments.

References:

- [Terraform Azure backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Azure RBAC scope](https://learn.microsoft.com/en-us/azure/role-based-access-control/scope-overview)
- [Azure custom roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles)
- [Azure storage container CLI](https://learn.microsoft.com/en-us/cli/azure/storage/container)
