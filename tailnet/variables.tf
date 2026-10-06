variable "tailnet_owner" {
  description = "Owner's exact Tailscale login identity (email, username@github, or username@passkey). Personal hosts must remain user-owned, untagged devices."
  type        = string

  validation {
    condition     = can(regex("^[^[:space:]@:]+@[^[:space:]@:]+$", var.tailnet_owner))
    error_message = "tailnet_owner must be your exact Tailscale login identity, such as you@example.com or username@github."
  }
}
