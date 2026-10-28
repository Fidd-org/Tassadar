resource "digitalocean_tag" "monitoring" {
  for_each = local.monitoring_configs

  name = "${var.name_prefix}-${each.key}"
}

resource "digitalocean_droplet" "monitoring" {
  for_each = local.monitoring_configs

  name       = "${var.name_prefix}-${each.key}"
  image      = each.value.image
  region     = var.region
  size       = each.value.size
  vpc_uuid   = data.digitalocean_vpc.pxc.id
  ssh_keys   = [local.admin_ssh_key.fingerprint]
  monitoring = true
  tags       = [digitalocean_tag.monitoring[each.key].name]

  user_data = <<-EOT
    #cloud-config
    ssh_pwauth: false
    disable_root: false
  EOT
}
