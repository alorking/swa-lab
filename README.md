# swa-lab

# Run sheet: Azure Static Web Apps behind Azure Front Door with Terraform and GitHub Actions

**Audience:** DevOps practitioner learning by building.  
**Outcome:** a static site is built and deployed by GitHub Actions; Azure Front Door (AFD) is its public CDN/edge entry point; Terraform owns the Azure infrastructure; GitHub uses short-lived OpenID Connect (OIDC) credentials to run Terraform.

This is intentionally a small, production-shaped baseline—not a copy/paste-only lab. At each checkpoint, inspect what Azure created, predict the next dependency, and use the linked documentation to answer questions before moving on.

## 0. The architecture you are building

```text
Browser
  │ https://<endpoint>.azurefd.net  (later: www.example.com)
  ▼
Azure Front Door Standard
  │ caches public assets, terminates TLS, adds X-Azure-FDID
  ▼
Azure Static Web App (Standard)
  │ hosts the built files; validates Front Door's identity
  ▼
GitHub Actions
  ├─ Terraform workflow: OIDC → Azure Resource Manager → infrastructure
  └─ App workflow: builds site → Static Web Apps deployment API
```

**Why both workflows?** Infrastructure and application artifacts change at different rates and require different authority. Terraform provisions stable control-plane objects; the Static Web Apps deployment action uploads the application content plane. Keeping them separate makes approvals, audit history, and rollback boundaries clearer.

### Design choices and scope

| Choice | This run sheet uses | Why |
|---|---|---|
| CDN | Front Door Standard | Global CDN, routing, managed TLS, and room for WAF/rules later. Premium is a deliberate upgrade when you need WAF/private-link features. |
| Hosting | Static Web Apps Standard | Required for `forwardingGateway` configuration, which is how the origin accepts Front Door and constructs correct redirects. |
| Azure auth from GitHub | OIDC federation | No long-lived Azure client secret is stored in GitHub. |
| DNS | AFD default hostname first | Removes domain/DNS variables while you prove traffic flow. Add your custom domain only after the baseline works. |
| State | Azure Storage remote backend | Team-safe state with a lock rather than a local `terraform.tfstate`. |

**Cost checkpoint:** Static Web Apps Standard and Front Door are chargeable. Read current pricing before applying, set a budget, and run the cleanup step at the end if this is only a lab.

## 1. Prerequisites and naming

Install and sign in locally:

```bash
az login
az account set --subscription "<subscription-id-or-name>"
az account show --query '{subscription:id, tenantId:tenantId, user:user.name}' -o yaml
terraform version
git --version
```

You also need a GitHub repository containing a small frontend. A plain `index.html` is enough for the first deployment.

Choose a unique `project` value (for example `swaedgejane01`) and a region (for example `australiaeast`). Front Door itself is global; the resource-group location is still required for the control-plane resources.

**Pause and investigate:**

- In the Azure Portal, find **Resource providers** for your subscription. Is `Microsoft.Cdn` registered? If not, run `az provider register --namespace Microsoft.Cdn`, then check `az provider show -n Microsoft.Cdn --query registrationState -o tsv`.
- Why must the Front Door endpoint name be globally unique while the resource group name only needs subscription-level uniqueness?

## 2. Create remote Terraform state (one-time bootstrap)

Do this under your own authenticated administrator/developer identity, *before* the CI identity exists. Replace all placeholders. Storage-account names are globally unique, lowercase, and 3–24 characters.

```bash
export TFSTATE_RG="rg-tfstate-<project>"
export TFSTATE_LOCATION="australiaeast"
export TFSTATE_SA="st<project><randomdigits>"

az group create --name "$TFSTATE_RG" --location "$TFSTATE_LOCATION"
az storage account create --name "$TFSTATE_SA" --resource-group "$TFSTATE_RG" \
  --location "$TFSTATE_LOCATION" --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false --min-tls-version TLS1_2
az storage container create --name tfstate --account-name "$TFSTATE_SA" --auth-mode login
```

**Why:** Terraform state maps resource addresses to real Azure IDs and can contain sensitive values. A remote backend gives a shared source of truth and Azure Blob leases provide locking. Do not commit state, `.terraform/`, `.tfvars`, or deployment tokens.

**Explore:** use `az storage container show --name tfstate --account-name "$TFSTATE_SA" --auth-mode login`. Then look up the `azurerm` backend authentication modes; for CI we will use OIDC rather than a storage key.

## 3. Create the repository layout

```text
.
├── index.html
├── staticwebapp.config.json
├── infra/
│   ├── versions.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.hcl.example
│   └── terraform.tfvars.example
└── .github/workflows/
    ├── terraform.yml
    └── deploy-app.yml
```

Create these files. Pin the provider major version, then let a reviewed lock file record exact versions. The configuration uses the current AzureRM v4 resource family for Front Door Standard/Premium (`azurerm_cdn_frontdoor_*`), not the older Front Door Classic resource.

### `infra/versions.tf`

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}
```

`backend "azurerm" {}` deliberately has no literal account details: initialization receives them from a local, ignored backend file or CI variables. The provider authenticates from `ARM_*` environment variables, which makes the same code usable locally and in GitHub Actions.

### `infra/variables.tf`

```hcl
variable "project" {
  description = "Short, lowercase identifier used in Azure resource names."
  type        = string
}

variable "location" {
  description = "Azure region for the resource group and Static Web App."
  type        = string
  default     = "australiaeast"
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"
}
```

### `infra/main.tf`

```hcl
locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = {
    environment = var.environment
    managed_by  = "terraform"
    workload    = "static-web-frontdoor"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_static_web_app" "this" {
  name                = "swa-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku_tier            = "Standard"
  sku_size            = "Standard"

  # Preview environments are useful for pull-request validation; revisit cost/governance later.
  preview_environments_enabled = true
  tags                         = local.tags
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = "afd-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = local.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  # Azure requires this to be globally unique. Change project if apply reports a collision.
  name                     = "afd-${var.project}-${var.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "this" {
  name                     = "swa-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  health_probe {
    protocol            = "Https"
    request_type        = "HEAD"
    path                = "/"
    interval_in_seconds = 100
  }

  load_balancing {
    sample_size                        = 4
    successful_samples_required         = 3
    additional_latency_in_milliseconds = 50
  }
}

resource "azurerm_cdn_frontdoor_origin" "swa" {
  name                          = "static-web-app"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  enabled                       = true
  host_name                     = azurerm_static_web_app.this.default_host_name
  origin_host_header            = azurerm_static_web_app.this.default_host_name
  http_port                     = 80
  https_port                    = 443
  priority                      = 1
  weight                        = 1000
  certificate_name_check_enabled = true
}

resource "azurerm_cdn_frontdoor_route" "all" {
  name                          = "all-content"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  # This is intentionally explicit: it also makes Terraform's creation/destruction ordering unambiguous.
  cdn_frontdoor_origin_ids = [azurerm_cdn_frontdoor_origin.swa.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  link_to_default_domain = true

  cache {
    query_string_caching_behavior = "UseQueryString"
  }
}
```

**Read the dependency chain:** `route → origin → origin group → profile`, while the origin hostname comes from the Static Web App. `origin_host_header` is not decorative: origins commonly require the Host header to match their own hostname. The explicit origin ID in the route is also a Terraform provider requirement for correct lifecycle ordering.

**Experiment before applying:** What would change if `forwarding_protocol` were `MatchRequest`? Why is HTTPS-only a safer steady state? Read the Front Door origin-host-header documentation and inspect the `default_host_name` in the provider docs.

### `infra/outputs.tf`

```hcl
output "front_door_url" {
  value       = "https://${azurerm_cdn_frontdoor_endpoint.this.host_name}"
  description = "Use this as the only public entry point during the baseline lab."
}

output "front_door_id" {
  value       = azurerm_cdn_frontdoor_profile.this.resource_guid
  description = "Copy into staticwebapp.config.json to require traffic from this Front Door."
}

output "static_web_app_default_hostname" {
  value       = azurerm_static_web_app.this.default_host_name
  description = "Diagnostic origin hostname; do not publish it as your user-facing URL."
}
```

### Local-only configuration files

`infra/backend.hcl.example`:

```hcl
resource_group_name  = "rg-tfstate-<project>"
storage_account_name = "st<project><randomdigits>"
container_name       = "tfstate"
key                  = "static-web-frontdoor/dev.tfstate"
use_azuread_auth     = true
```

`infra/terraform.tfvars.example`:

```hcl
project     = "replace-with-unique-project"
location    = "australiaeast"
environment = "dev"
```

Copy each example to the same name without `.example`; keep the real files out of Git if they identify your tenancy or environment. Add this `.gitignore`:

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
backend.hcl
crash.log
```

The local backend file uses your existing Azure CLI session. The CI workflow supplies `use_oidc=true` separately; do not put that setting in this local file unless your local session is itself configured for workload identity federation.

## 4. Validate and apply locally once

```bash
cd infra
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
# Edit both files now.

export ARM_USE_AZUREAD=true
terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output
```

**Why a saved plan?** It lets you inspect the precise reviewed change that is applied. In CI, generate a fresh plan per run and promote only with your chosen approval policy.

**Checkpoint:** In the Azure Portal, open the Front Door profile, endpoint, route, origin group and origin. Confirm the origin health turns healthy. A `200` from the endpoint may initially show the platform default until the application is deployed.

## 5. Deploy a minimal application and protect the origin

Create `index.html`:

```html
<!doctype html>
<html><body><h1>Front Door → Static Web Apps works</h1></body></html>
```

The following `staticwebapp.config.json` is the crucial edge/origin contract. Initially replace `<FRONT_DOOR_RESOURCE_GUID>` with `terraform output -raw front_door_id`.

```json
{
  "forwardingGateway": {
    "allowedForwardedHosts": [
      "<your-endpoint>.azurefd.net"
    ],
    "requiredHeaders": {
      "X-Azure-FDID": "<FRONT_DOOR_RESOURCE_GUID>"
    }
  },
  "routes": [
    {
      "route": "/admin/*",
      "allowedRoles": ["administrator"],
      "headers": {
        "Cache-Control": "no-store"
      }
    }
  ]
}
```

**Why:** Front Door adds `X-Azure-FDID` to backend requests. Requiring the profile GUID stops direct requests to the `*.azurestaticapps.net` origin. `allowedForwardedHosts` tells Static Web Apps which forwarded hostnames are legitimate when it builds redirects. Do not cache authenticated or user-specific routes; cache configuration is a security decision, not merely a performance toggle.

**Important sequencing:** the policy only takes effect when this app configuration is deployed. In a production change, deploy the configuration promptly after infrastructure and verify both paths. You should expect the direct origin to be rejected after the configuration is live, while the Front Door address keeps working.

Get the deployment token locally (do not paste it into a file or terminal recording):

```bash
az staticwebapp secrets list \
  --name "swa-<project>-dev" --resource-group "rg-<project>-dev" \
  --query properties.apiKey -o tsv
```

In GitHub repository **Settings → Secrets and variables → Actions**, save it as `AZURE_STATIC_WEB_APPS_API_TOKEN`. This token is for content deployment, not Terraform. It has a different scope from the OIDC Azure identity.

## 6. Bootstrap GitHub-to-Azure OIDC for Terraform

Create an Entra application/service principal and give it only the access it needs. The sample uses a resource-group-scoped Contributor role and Blob Data Contributor on the *state storage account*. Run as a user authorised to create app registrations and role assignments:

```bash
export SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TENANT_ID="$(az account show --query tenantId -o tsv)"
export APP_NAME="gha-tf-<project>-dev"
export TARGET_RG="rg-<project>-dev"
export GITHUB_ORG="<github-owner>"
export GITHUB_REPO="<repository>"

export CLIENT_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
az ad sp create --id "$CLIENT_ID"

az role assignment create --assignee "$CLIENT_ID" --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$TARGET_RG"
az role assignment create --assignee "$CLIENT_ID" --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$TFSTATE_RG/providers/Microsoft.Storage/storageAccounts/$TFSTATE_SA"

az ad app federated-credential create --id "$CLIENT_ID" --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:'"$GITHUB_ORG/$GITHUB_REPO"':ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

**Why OIDC:** GitHub asks for an identity token during a run; Entra only exchanges it when its claims match the federated credential. The `subject` ties this credential to exactly one repository and branch. For real promotion flows, use a separate subject and identity per GitHub Environment (for example `repo:ORG/REPO:environment:production`) with environment approvals.

Add these GitHub **repository variables** (they are identifiers, not credentials): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`, and `PROJECT` (the same value you used in `terraform.tfvars`). Keep the deployment token in a **secret**.

**Research prompt:** compare `Contributor` with the roles actually required by your Terraform plan. Can you make a custom role? What happens if the CI identity can change its own role assignments? Keep it unable to do so.

## 7. Add the GitHub Actions workflows

`.github/workflows/terraform.yml`:

```yaml
name: Terraform

on:
  pull_request:
    paths: ["infra/**", ".github/workflows/terraform.yml"]
  push:
    branches: [main]
    paths: ["infra/**", ".github/workflows/terraform.yml"]

permissions:
  contents: read
  id-token: write # Allows GitHub to request the OIDC token; it does not grant Azure access alone.

jobs:
  plan-and-apply:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: infra
    env:
      ARM_USE_OIDC: true
      ARM_USE_AZUREAD: true
      ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
      ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      TF_VAR_project: ${{ vars.PROJECT }}
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@v3
      - name: Init
        run: >-
          terraform init
          -backend-config="resource_group_name=${{ vars.TFSTATE_RESOURCE_GROUP }}"
          -backend-config="storage_account_name=${{ vars.TFSTATE_STORAGE_ACCOUNT }}"
          -backend-config="container_name=tfstate"
          -backend-config="key=static-web-frontdoor/dev.tfstate"
          -backend-config="use_azuread_auth=true"
          -backend-config="use_oidc=true"
      - run: terraform fmt -check
      - run: terraform validate
      - run: terraform plan -out=tfplan
      - name: Apply on main only
        if: github.event_name == 'push'
        run: terraform apply -auto-approve tfplan
```

This compact workflow plans pull requests and applies only after a push to `main`. For a production repository, split plan/apply into jobs, retain a reviewed plan artifact, use a protected GitHub Environment for apply, pin third-party actions to commit SHAs, and use dependency updates. Those are worthwhile exercises rather than hidden magic.

`.github/workflows/deploy-app.yml`:

```yaml
name: Deploy static site

on:
  push:
    branches: [main]
    paths: ["index.html", "staticwebapp.config.json", "src/**", "package.json", ".github/workflows/deploy-app.yml"]

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        uses: Azure/static-web-apps-deploy@v1
        with:
          azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          repo_token: ${{ secrets.GITHUB_TOKEN }}
          action: upload
          app_location: "/"
          output_location: ""
```

For a framework application, set `app_location` to source and `output_location` to its build directory. Read the action’s documented build settings instead of guessing them—its defaults vary by project shape.

## 8. Verification run sheet

After the first successful workflows:

1. Open `terraform output -raw front_door_url`; confirm the marker page appears over HTTPS.
2. In Front Door metrics, check origin health and request count. AFD propagation can take a few minutes.
3. Test redirects: `curl -I http://<endpoint>.azurefd.net` should redirect to HTTPS.
4. Test the Static Web Apps origin *after* the configuration deployment: `curl -I https://$(terraform output -raw static_web_app_default_hostname)`. It should no longer be a usable public route; validate the status/body against your policy.
5. Add a deliberately cacheable versioned asset and inspect response headers twice through AFD. Then add an authenticated test route and verify `Cache-Control: no-store` is retained.
6. Read GitHub’s workflow run log. Confirm Terraform login never used an Azure client secret and that the job had `id-token: write`.

If the AFD endpoint fails while the origin works, inspect route association, origin host header, origin health and DNS. If direct-origin blocking also blocks AFD, compare the `front_door_id` output with the deployed JSON and confirm the endpoint hostname is in `allowedForwardedHosts`.

## 9. Add a custom domain only after the baseline

At a high level, the ownership boundary changes to:

```text
DNS zone: CNAME www.example.com → <endpoint>.azurefd.net
AFD: custom domain + managed certificate + route association
SWA config: add www.example.com to allowedForwardedHosts
```

Do not point a public domain at the Static Web App origin when your intention is to force Front Door. Use an AFD custom-domain resource and associate its ID with the route, then create the DNS validation/alias record required by your DNS provider. Azure-managed certificates are the default sensible option. If Azure DNS hosts the zone, Terraform can manage the records; with an external registrar, create and verify the record there.

Before implementation, answer these from the Terraform Registry and Azure docs: Which record validates the domain? When is the certificate issued? How would you rotate a customer-managed certificate? What needs changing in `allowedForwardedHosts`? Test a subdomain (`www`) before attempting an apex domain.

## 10. Production hardening backlog

- Add a Front Door WAF policy and attach it to the endpoint; use managed rules, rate limiting, and a monitoring/false-positive period before blocking.
- Add diagnostic settings for Front Door and Static Web Apps to Log Analytics; set alerts for origin health, 5xx rate, and WAF blocks.
- Use distinct state keys, resource groups, identities, and Front Door endpoints for dev/test/prod. Never represent environments as a hand-edited variable alone.
- Separate Terraform `plan` and `apply`; require protected-environment approval for apply and restrict OIDC federated subjects to those environments.
- Use a custom domain, HSTS (after testing), explicit cache-control headers, and an invalidation/deployment strategy for HTML versus immutable hashed assets.
- Establish backup/rollback practice: application rollback via a previous artifact/commit; infrastructure rollback via a reviewed Terraform change—not an unexamined `destroy`.

## 11. Cleanup (lab only)

First delete the workload resources using Terraform, then deliberately remove the state storage only after you have no state to preserve:

```bash
cd infra
terraform destroy
```

Review the plan before approving. The bootstrap state resource group is intentionally outside this Terraform configuration; delete it manually only when you are certain it is not shared by another environment.

## Authoritative references

- [Configure Azure Front Door with Azure Static Web Apps](https://learn.microsoft.com/en-us/azure/static-web-apps/front-door-manual) — plan requirements, `X-Azure-FDID`, caching, and the managed enterprise-edge alternative.
- [Static Web Apps configuration: forwarding gateway](https://learn.microsoft.com/en-us/azure/static-web-apps/configuration#forwarding-gateway) — `allowedForwardedHosts` and `requiredHeaders` semantics.
- [Azure Front Door Terraform quickstart](https://learn.microsoft.com/en-us/azure/frontdoor/create-front-door-terraform) — Front Door v2 resource model and origin-host-header guidance.
- [Azure Login with GitHub OIDC](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) — federated credentials and required workflow permissions.
- [AzureRM Static Web App resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/static_web_app) and [Front Door route resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_route) — current provider arguments and lifecycle notes.
