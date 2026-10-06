# This root owns the whole Tailnet policy. It has its own working directory and local state;
# Robot server lifecycle commands run at the repo root and never enter this module (ADR 0012).
locals {
  policy = {
    tagOwners = {
      "tag:server" = [var.tailnet_owner]
    }
    grants = [
      {
        # User identities select only their untagged devices. The Robot server's tag replaces
        # its user identity, so it cannot initiate connections through this grant.
        src = [var.tailnet_owner]
        dst = [var.tailnet_owner, "tag:server"]
        ip  = ["tcp:22", "tcp:443", "udp:60000-61000"]
      }
    ]
    tests = [
      {
        src    = var.tailnet_owner
        proto  = "tcp"
        accept = ["${var.tailnet_owner}:22", "${var.tailnet_owner}:443", "tag:server:22", "tag:server:443"]
      },
      {
        src    = var.tailnet_owner
        proto  = "udp"
        accept = ["${var.tailnet_owner}:60000", "${var.tailnet_owner}:61000", "tag:server:60000", "tag:server:61000"]
      },
      {
        src   = "tag:server"
        proto = "tcp"
        deny  = ["${var.tailnet_owner}:22", "${var.tailnet_owner}:443"]
      },
      {
        src   = "tag:server"
        proto = "udp"
        deny  = ["${var.tailnet_owner}:60000", "${var.tailnet_owner}:61000"]
      }
    ]
  }
}

resource "tailscale_acl" "policy" {
  acl                        = jsonencode(local.policy)
  overwrite_existing_content = true
  reset_acl_on_destroy       = false

  # An accidental destroy must not replace this boundary with Tailscale's allow-all default.
  lifecycle {
    prevent_destroy = true
  }
}
