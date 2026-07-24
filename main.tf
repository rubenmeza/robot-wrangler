locals {
  # Every devices/*.pub is a control-surface device. Public keys are not secret, so they are
  # committed to the repo. cloud-init seeds them into the robot user's authorized_keys.
  device_pubkeys = [for f in fileset(path.module, "devices/*.pub") : trimspace(file("${path.module}/${f}"))]

  # The on-box briefing that primes every agent session (server facts + standing security rules).
  claude_md = templatefile("${path.module}/files/CLAUDE.md.tmpl", {
    hostname   = var.ts_hostname
    region     = var.region
    size       = var.size
    robot_user = var.robot_user
    ts_tags    = var.ts_tags
  })

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    robot_user        = var.robot_user
    tailscale_authkey = var.tailscale_authkey
    ts_hostname       = var.ts_hostname
    ts_tags           = var.ts_tags
    ssh_pubkeys       = local.device_pubkeys
    claude_md_b64     = base64encode(local.claude_md)
    git_author_name   = var.git_author_name
    git_author_email  = var.git_author_email
  })
}

resource "digitalocean_droplet" "robot" {
  name       = var.ts_hostname
  image      = var.image
  size       = var.size
  region     = var.region
  ipv6       = true
  monitoring = true
  backups    = var.backups
  user_data  = local.user_data
  tags       = ["robot", "managed-by-opentofu"]

  # Daily backups (only valid when backups = true).
  dynamic "backup_policy" {
    for_each = var.backups ? [1] : []
    content {
      plan = "daily"
      hour = 4
    }
  }

  lifecycle {
    # Changing user_data forces a replace. Don't recreate the box on trivial template edits.
    # To re-provision on purpose: `make robot-destroy && make robot-wrangler`.
    ignore_changes = [user_data]
  }
}

resource "digitalocean_firewall" "robot" {
  name        = "${var.ts_hostname}-locked"
  droplet_ids = [digitalocean_droplet.robot.id]

  # No inbound_rule blocks => DENY ALL inbound from the public internet.
  # The box is reached only over Tailscale, which is established outbound (DERP-relayed),
  # so it needs no open public port. This is the "born-locked" property (see ADR 0001).

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
