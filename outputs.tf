output "droplet_id" {
  description = "DigitalOcean droplet id."
  value       = digitalocean_droplet.robot.id
}

output "public_ip" {
  description = "Public IPv4. Should be UNREACHABLE (firewall denies all inbound). Break-glass via DO console only."
  value       = digitalocean_droplet.robot.ipv4_address
}

output "tailnet_host" {
  description = "Tailscale hostname to reach the box."
  value       = var.ts_hostname
}

output "device_keys_loaded" {
  description = "How many devices/*.pub keys were seeded. If 0, you locked yourself out — add a key and recreate."
  value       = length(local.device_pubkeys)
}
