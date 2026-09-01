variable "monitoring" {
  description = "Dokploy source and Tailscale-only UI routing settings for the monitoring stack"

  type = object({
    github_provider_name = string
    github_owner         = string
    github_repository    = string
    github_branch        = optional(string, "main")
    grafana_host         = string
    prometheus_host      = optional(string, "prometheus.home.arpa")
  })
}

data "dokploy_github_providers" "monitoring" {}

locals {
  monitoring_github_provider = one([
    for provider in data.dokploy_github_providers.monitoring.providers : provider
    if provider.name == var.monitoring.github_provider_name
  ])
}

resource "dokploy_project" "monitoring" {
  name        = "Monitoring"
  description = "📊 Self-hosted Grafana, Prometheus, Loki, Tempo, and Alloy"
}

# Dokploy normalizes every environment description to this provider value.
resource "dokploy_environment" "monitoring" {
  name        = "production"
  description = "Production environment"
  project_id  = dokploy_project.monitoring.id

  # The provider marks project_id unknown while updating project metadata, then
  # plans an invalid replacement of Dokploy's undeletable default environment.
  lifecycle {
    ignore_changes = [project_id]
  }
}

# Dokploy clones this repository before it deploys the stack. This is required
# because the stack uses relative Docker config files under stacks/monitoring/.
resource "dokploy_compose" "monitoring" {
  name           = "observability"
  description    = "Single-node LGTM monitoring stack"
  environment_id = dokploy_environment.monitoring.id
  source_type    = "github"
  compose_type   = "stack"

  github_id    = local.monitoring_github_provider.id
  owner        = var.monitoring.github_owner
  repository   = var.monitoring.github_repository
  branch       = var.monitoring.github_branch
  compose_path = "stacks/monitoring/docker-stack.yml"

  # Values in this string are available for Compose interpolation only. Do not
  # put Grafana admin passwords, SMTP credentials, or API keys here: Terraform
  # state retains sensitive values. Grafana uses its default initial credential
  # for this Tailscale-only learning environment; change it immediately at the
  # first sign-in rather than adding a password to Terraform state.
  env = join("\n", [
    file("${path.module}/../../stacks/monitoring/dokploy.env"),
    "GRAFANA_HOST=${var.monitoring.grafana_host}",
  ])

  # Deploy this GitHub-backed Stack deliberately from Dokploy; it must not
  # redeploy whenever a repository push changes a watched path.
  auto_deploy      = false
  deploy_on_create = true
  watch_paths      = ["stacks/monitoring/**"]
}

# Dokploy owns the HTTP-only Traefik routes. The host firewall permits access
# to them only via Tailscale. All other stack services remain overlay-only.
resource "dokploy_domain" "grafana" {
  compose_id         = dokploy_compose.monitoring.id
  service_name       = "grafana"
  host               = var.monitoring.grafana_host
  port               = 3000
  https              = false
  certificate_type   = "none"
  redeploy_on_update = true
}

# Prometheus has no authentication in this homelab deployment, so this route is
# deliberately HTTP-only and protected by the Tailscale-only firewall rule.
resource "dokploy_domain" "prometheus" {
  compose_id         = dokploy_compose.monitoring.id
  service_name       = "prometheus"
  host               = var.monitoring.prometheus_host
  port               = 9090
  https              = false
  certificate_type   = "none"
  redeploy_on_update = true
}
