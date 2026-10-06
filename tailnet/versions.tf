terraform {
  required_version = ">= 1.6"
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29.2"
    }
  }
}

provider "tailscale" {
  # API credential and Tailnet ID are read from this module's environment only.
  # Neither is passed to the Robot server or its cloud-init configuration.
}
