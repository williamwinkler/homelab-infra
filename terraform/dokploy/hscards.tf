
variable "github_provider_name" {
  description = "Name of the GitHub provider configured in Dokploy"
  type        = string
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repository"
  type        = string
}

variable "web" {
  description = "web application deployment settings"

  type = object({
    github_branch     = string
    github_repository = string
    build_type        = string
  })
}

data "dokploy_github_providers" "configured" {}

locals {
  github_provider = one([
    for provider in data.dokploy_github_providers.configured.providers : provider
    if provider.name == var.github_provider_name
  ])
}

resource "dokploy_project" "default" {
  name        = "hscards_tf"
  description = "Hearthstone cards test"
}

resource "dokploy_environment" "default" {
  name       = "prod"
  project_id = dokploy_project.default.id
}

resource "dokploy_application" "web" {
  name           = "web"
  environment_id = dokploy_environment.default.id
  source_type    = "github"

  github_id         = local.github_provider.id
  github_owner      = var.github_owner
  github_branch     = var.web.github_branch
  github_repository = var.web.github_repository

  build_type = var.web.build_type

  auto_deploy      = true
  deploy_on_create = false
}

resource "dokploy_environment_variables" "hscards_web_env_vars" {
  application_id = dokploy_application.web.id

  variables = {
    VITE_API_BASE_URL = "https://hscards.william-winkler.com/api/v1"
  }
}
