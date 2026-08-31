variable "dokploy_host" {
  description = "Dokploy API URL, including /api"
  type        = string
}

variable "dokploy_api_key" {
  description = "Dokploy API key"
  type        = string
  sensitive   = true
}

