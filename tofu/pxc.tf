resource "digitalocean_volume" "pxc_data" {
  for_each = local.pxc_nodes

  name                    = "${each.key}-data"
  region                  = var.region
  size                    = local.pxc_config.data_disk_size
  initial_filesystem_type = "ext4"
  description             = "MySQL data volume for ${each.key}."
  tags                    = [digitalocean_tag.pxc.name]
}

resource "digitalocean_droplet" "pxc" {
  for_each = local.pxc_nodes

  name       = each.key
  image      = local.pxc_config.image
  region     = var.region
  size       = local.pxc_config.size
  vpc_uuid   = data.digitalocean_vpc.pxc.id
  ssh_keys   = [local.admin_ssh_key.fingerprint]
  monitoring = true
  tags       = [digitalocean_tag.pxc.name]

  user_data = local.automation_cloud_init
}

resource "digitalocean_volume_attachment" "pxc_data" {
  for_each = local.pxc_nodes

  droplet_id = digitalocean_droplet.pxc[each.key].id
  volume_id  = digitalocean_volume.pxc_data[each.key].id
}
