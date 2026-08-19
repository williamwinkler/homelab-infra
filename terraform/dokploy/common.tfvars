dokploy_host         = "https://dokploy.william-winkler.com/api"
github_provider_name = "dokploy-home-william-winkler"
github_owner         = "williamwinkler"

web = {
  github_branch     = "master"
  github_repository = "hs-card-web"
  build_type        = "nixpacks"
}

api = {
  github_branch     = "master"
  github_repository = "hs-card-service"
  build_type        = "dockerfile"
}
