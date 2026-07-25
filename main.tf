locals {
  # Every devices/*.pub is a control-surface device. Public keys are not secret, so they are
  # committed to the repo. cloud-init seeds them into the robot user's authorized_keys.
  device_pubkeys = [for f in fileset(path.module, "devices/*.pub") : trimspace(file("${path.module}/${f}"))]

  # The on-box briefing that primes every agent session (server facts + standing security rules).
  claude_md = templatefile("${path.module}/files/CLAUDE.md.tmpl", {
    hostname    = var.ts_hostname
    region      = var.region
    size        = var.size
    robot_user  = var.robot_user
    ts_tags     = var.ts_tags
    multiplexer = var.robot_multiplexer
  })

  # Non-secret config the Provisioner sources at runtime (ADR 0006). Keeps render-time values out
  # of provision.sh, which ships verbatim so it stays shellcheck-clean and container-runnable.
  provision_env = templatefile("${path.module}/files/provision.env.tftpl", {
    robot_user       = var.robot_user
    git_author_name  = var.git_author_name
    git_author_email = var.git_author_email
    ts_hostname      = var.ts_hostname
    ts_tags          = var.ts_tags
  })

  # Login-shell drop-in: PATH, secret env, and the auto-attach target (the multiplexer profile,
  # ADR 0003, baked in at provision time).
  profile_d = templatefile("${path.module}/files/profile.d-robot.sh.tftpl", {
    robot_user  = var.robot_user
    multiplexer = var.robot_multiplexer
  })

  # The Provisioner ships VERBATIM (no templatefile) so it is a real, lintable, runnable script.
  provision_sh = file("${path.module}/files/provision.sh")

  # The manifest is a thin list of WHAT. Every dynamic payload is base64'd (encoding: b64), so no
  # non-ASCII byte can ever void the #cloud-config.
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    robot_user        = var.robot_user
    ssh_pubkeys       = local.device_pubkeys
    console_pw_hash   = var.robot_console_password_hash
    claude_md_b64     = base64encode(local.claude_md)
    provision_sh_b64  = base64encode(local.provision_sh)
    provision_env_b64 = base64encode(local.provision_env)
    profile_d_b64     = base64encode(local.profile_d)
    authkey_b64       = base64encode(var.tailscale_authkey)
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
