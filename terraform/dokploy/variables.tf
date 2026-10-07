variable "dokploy_host" {
  description = "Dokploy API URL, including /api"
  type        = string
}

variable "dokploy_api_key" {
  description = "Dokploy API key"
  type        = string
  sensitive   = true
}

variable "tikkit" {
  description = "Tikkit images and Cloudflare Tunnel origin settings; credentials live in Dokploy shared variables"
  type = object({
    api_image         = string
    web_image         = string
    registry_username = string
    host              = optional(string, "tikkit.life")
    database_networks = optional(set(string), [])
  })
}

variable "tikkit_registry_token" {
  description = "Docker Hub personal access token with Public Repo Read-only scope, for Dokploy's image pull"
  type        = string
  sensitive   = true
}
