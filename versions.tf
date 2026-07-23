terraform {
  required_version = ">= 1.6"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.43"
    }
  }
}

provider "digitalocean" {
  # Token is read from the DIGITALOCEAN_TOKEN env var (set in .env, sourced by the scripts).
  # It is used ONLY here, on your machine, to call the DO API. It never touches the droplet.
}
