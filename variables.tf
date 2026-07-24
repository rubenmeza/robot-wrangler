variable "tailscale_authkey" {
  description = "One-time, pre-authorized, tagged Tailscale auth key (tag:server). Baked into cloud-init; spent on first boot. Set via TF_VAR_tailscale_authkey in .env."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region slug. nyc3 or sfo3 are closest to Queretaro, MX."
  type        = string
  default     = "nyc3"
}

variable "size" {
  description = "Droplet size slug. s-4vcpu-8gb = 8GB/4vCPU/160GB, $48/mo (Claude Code recommended size)."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "image" {
  description = "Base image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ts_hostname" {
  description = "Tailscale hostname for the box; also the droplet name and the ssh user."
  type        = string
  default     = "robot"
}

variable "ts_tags" {
  description = "Tailscale ACL tag applied to the box. Tagged nodes never expire, which is what we want for a server."
  type        = string
  default     = "tag:server"
}

variable "robot_user" {
  description = "Non-root sudo user that runs the agent. SSH is key-only for this user."
  type        = string
  default     = "robot"
}

variable "backups" {
  description = "Enable DigitalOcean daily droplet backups (+20% of droplet price)."
  type        = bool
  default     = true
}

variable "git_author_name" {
  description = "Name used for the robot's git commits. Commits are authored as the owner (see ADR 0002)."
  type        = string
  default     = "Ruben Meza"
}

variable "git_author_email" {
  description = "Email used for the robot's git commits. Matches the owner's laptop identity (see ADR 0002)."
  type        = string
  default     = "rmezar@gmail.com"
}
