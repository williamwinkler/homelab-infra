# Terraform

## Install

```zsh
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
brew install terraform-linters/tap/tflint

terraform version
tflint --version
```

## Shared personal workflow

This private repository intentionally tracks
`terraform/dokploy/terraform.tfstate` and the non-secret
`terraform/dokploy/common.tfvars`. A laptop that clones the repository has the
current resource IDs and therefore does not need Terraform imports.

On each laptop:

```zsh
cd terraform/dokploy
cp .env.example .env
# Store the real Dokploy API key in .env, then:
set -a; source .env; set +a
terraform init
terraform plan -var-file=common.tfvars
```

Commit and push the changed `terraform.tfstate` immediately after every apply.
Pull before each plan or apply, and never apply concurrently from two laptops:
Git does not provide Terraform state locking.

Do not commit `.env`, arbitrary `*.tfvars`, `.terraform/`, crash logs, or state
backup files. The committed lock file lets `terraform init` restore the correct
provider versions on every supported laptop.
