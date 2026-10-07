locals {
  tikkit_network = yamldecode(file("${path.module}/../../ansible/vars/tikkit.yml")).tikkit_network
  tikkit_api_networks = sort(tolist(setunion(
    toset(["dokploy-network", "observability", local.tikkit_network.name]), var.tikkit.database_networks
  )))
}

resource "dokploy_project" "tikkit" {
  name        = "TIKKIT"
  description = "Issue tracker: static SPA and Phoenix API"
}

resource "dokploy_environment" "tikkit" {
  name        = "production"
  description = "Production environment"
  project_id  = dokploy_project.tikkit.id

  lifecycle {
    ignore_changes = [project_id]
  }
}

resource "dokploy_application" "tikkit_web" {
  name           = "web"
  environment_id = dokploy_environment.tikkit.id

  # Public Docker Hub image built by tikkit's scripts/docker-push.sh. Dokploy
  # pulls the tag on every Deploy, then force-updates the Swarm service.
  source_type  = "docker"
  docker_image = var.tikkit.web_image
  # Dokploy 0.30 requires registry credentials even for public images, and
  # provider 0.8.0 omits empty strings. A Public-Repo-Read-only token grants
  # nothing beyond anonymous access, so its copy in committed state is harmless.
  registry_url = "docker.io"
  username     = var.tikkit.registry_username
  password     = var.tikkit_registry_token
  # Unused for image apps; Dokploy normalizes the provider's "./Dockerfile".
  dockerfile_path = "Dockerfile"

  create_env_file = false

  replicas                    = 1
  auto_deploy                 = false
  preview_deployments_enabled = false
  deploy_on_create            = false
  network_swarm               = jsonencode([{ Target = "dokploy-network" }])
  update_config_swarm         = jsonencode({ Parallelism = 1, Order = "stop-first" })
  placement_swarm             = jsonencode({ Constraints = ["node.role == manager"] })
  labels_swarm = jsonencode({
    "service.name"                = "tikkit-web"
    "deployment.environment.name" = "production"
  })
}

resource "dokploy_application" "tikkit_api" {
  name           = "api"
  environment_id = dokploy_environment.tikkit.id

  # Public Docker Hub image built by tikkit's scripts/docker-push.sh. Dokploy
  # pulls the tag on every Deploy, then force-updates the Swarm service.
  source_type  = "docker"
  docker_image = var.tikkit.api_image
  # Dokploy 0.30 requires registry credentials even for public images, and
  # provider 0.8.0 omits empty strings. A Public-Repo-Read-only token grants
  # nothing beyond anonymous access, so its copy in committed state is harmless.
  registry_url = "docker.io"
  username     = var.tikkit.registry_username
  password     = var.tikkit_registry_token
  # Unused for image apps; Dokploy normalizes the provider's "./Dockerfile".
  dockerfile_path = "Dockerfile"

  create_env_file = false

  # Dokploy splits this field on spaces, so keep shell logic in a file mount.
  command = "/bin/sh /app/dokploy/start.sh"

  # Only references are stored in Terraform. Set real values in the production
  # environment's shared variables, NOT this app's environment editor.
  # The pinned provider's environment resource does not read/write shared env.
  env = join("\n", [
    "DATABASE_URL=$${{environment.DATABASE_URL}}",
    "SECRET_KEY_BASE=$${{environment.SECRET_KEY_BASE}}",
    "TOKEN_SIGNING_SECRET=$${{environment.TOKEN_SIGNING_SECRET}}",
    "GOOGLE_CLIENT_ID=$${{environment.GOOGLE_CLIENT_ID}}",
    "GOOGLE_CLIENT_SECRET=$${{environment.GOOGLE_CLIENT_SECRET}}",
    "RELEASE_COOKIE=$${{environment.RELEASE_COOKIE}}",
    "PHX_HOST=${var.tikkit.host}",
    "WEB_URL=https://${var.tikkit.host}",
    "GOOGLE_REDIRECT_URI=https://${var.tikkit.host}/api/auth/user/google/callback",
    "PORT=4000",
    "POOL_SIZE=10",
    "RELEASE_DISTRIBUTION=name",
    # This alias exists ONLY on the cluster overlay, never on other networks.
    "DNS_CLUSTER_QUERY=tasks.tikkit-api-cluster",
    "TIKKIT_CLUSTER_IP_PREFIX=${trimsuffix(cidrhost(local.tikkit_network.subnet, 0), "0")}",
    "OTEL_ENABLED=true",
    "OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318",
    "OTEL_EXPORTER_OTLP_PROTOCOL=http_protobuf",
    "OTEL_RESOURCE_ATTRIBUTES=service.name=tikkit-api,service.namespace=tikkit,deployment.environment.name=production",
  ])

  replicas                    = 1
  auto_deploy                 = false
  preview_deployments_enabled = false
  deploy_on_create            = false
  network_swarm = jsonencode([
    for network in local.tikkit_api_networks : {
      Target  = network
      Aliases = network == local.tikkit_network.name ? ["tikkit-api-cluster"] : []
    }
  ])

  lifecycle {
    precondition {
      condition     = can(regex("^([0-9]{1,3}\\.){3}0/24$", local.tikkit_network.subnet)) && can(cidrhost(local.tikkit_network.subnet, 1))
      error_message = "Tikkit's cluster overlay must use a valid IPv4 /24 subnet."
    }
  }

  # Dokploy file mounts live on this single homelab manager.
  placement_swarm = jsonencode({ Constraints = ["node.role == manager"] })
  labels_swarm = jsonencode({
    "service.name"                = "tikkit-api"
    "deployment.environment.name" = "production"
  })
  health_check_swarm = jsonencode({
    Test        = ["CMD", "/bin/sh", "/app/dokploy/healthcheck.sh"]
    Interval    = 10000000000
    Timeout     = 8000000000
    StartPeriod = 120000000000
    Retries     = 3
  })
  update_config_swarm = jsonencode({
    Parallelism = 1
    Order       = "start-first"
    # Releases reuse the mutable :latest tag. Pause rather than "roll back" to a
    # previous service spec that references the very same tag.
    FailureAction   = "pause"
    Monitor         = 180000000000
    MaxFailureRatio = 0
  })
  rollback_config_swarm = jsonencode({
    Parallelism     = 1
    Order           = "start-first"
    FailureAction   = "pause"
    Monitor         = 180000000000
    MaxFailureRatio = 0
  })
  restart_policy_swarm    = jsonencode({ Condition = "any", Delay = 5000000000 })
  stop_grace_period_swarm = 60000000000
}

resource "dokploy_mount" "tikkit_api_runtime" {
  for_each = toset(["start.sh", "healthcheck.sh", "cluster_ready.exs"])

  service_id   = dokploy_application.tikkit_api.id
  service_type = "application"
  type         = "file"
  file_path    = each.value
  mount_path   = "/app/dokploy/${each.value}"
  content      = file("${path.module}/tikkit/${each.value}")
}

# Cloudflare terminates TLS. Its origin must be Dokploy's Traefik on port 80,
# preserving Host; API path routes take priority over the host-only web route.
# Do not strip these prefixes: Phoenix expects the complete paths.
resource "dokploy_domain" "tikkit_web" {
  application_id     = dokploy_application.tikkit_web.id
  host               = var.tikkit.host
  path               = "/"
  port               = 80
  https              = false
  certificate_type   = "none"
  redeploy_on_update = false
}

resource "dokploy_domain" "tikkit_api" {
  for_each = toset(["/api", "/socket", "/mcp"])

  application_id     = dokploy_application.tikkit_api.id
  host               = var.tikkit.host
  path               = each.value
  port               = 4000
  https              = false
  certificate_type   = "none"
  redeploy_on_update = false
}

output "tikkit_deployment" {
  description = "Non-secret names and URL for the manual deployment runbook"
  value = {
    url              = "https://${var.tikkit.host}"
    api_service_name = dokploy_application.tikkit_api.app_name
    web_service_name = dokploy_application.tikkit_web.app_name
    api_networks     = local.tikkit_api_networks
  }
}
