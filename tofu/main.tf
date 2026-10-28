# Root module for production infrastructure.

data "digitalocean_ssh_keys" "admin" {
  filter {
    key    = "public_key"
    values = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
  }
}

locals {
  admin_ssh_key = one(data.digitalocean_ssh_keys.admin.ssh_keys)
}

resource "digitalocean_tag" "bastion" {
  name = "${var.name_prefix}-bastion"
}

resource "digitalocean_tag" "pxc" {
  name = "${var.name_prefix}-pxc"
}

resource "digitalocean_tag" "flowerca" {
  name = "flowerca"
}

resource "digitalocean_project_resources" "tassadar" {
  count = var.project_id == null ? 0 : 1

  project = var.project_id
  resources = concat(
    [digitalocean_droplet.bastion.urn],
    [for droplet in digitalocean_droplet.pxc : droplet.urn],
    [digitalocean_droplet.flowerca.urn],
    [for droplet in digitalocean_droplet.monitoring : droplet.urn],
    [for volume in digitalocean_volume.pxc_data : volume.urn],
  )
}
