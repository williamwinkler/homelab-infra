// pi-lens-ignore: unknown
dokploy_host = "http://willy-server.hale-slowworm.ts.net:3000/api"
// pi-lens-ignore: unknown
monitoring = {
  github_provider_name = "dokploy-home-william-winkler"
  github_owner         = "williamwinkler"
  github_repository    = "homelab-infra"
  github_branch        = "main"
  grafana_host         = "grafana.home.arpa"
  prometheus_host      = "prometheus.home.arpa"
}

tikkit = {
  api_image         = "docker.io/williamwinkler/tikkit-api:latest"
  web_image         = "docker.io/williamwinkler/tikkit-web:latest"
  registry_username = "williamwinkler"
  host              = "tikkit.life"
  database_networks = []
}
