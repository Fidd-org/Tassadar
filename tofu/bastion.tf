resource "digitalocean_droplet" "bastion" {
  name       = "${var.name_prefix}-bastion"
  image      = local.bastion_config.image
  region     = var.region
  size       = local.bastion_config.size
  vpc_uuid   = data.digitalocean_vpc.pxc.id
  ssh_keys   = [local.admin_ssh_key.fingerprint]
  monitoring = true
  tags       = [digitalocean_tag.bastion.name]

  user_data = local.automation_cloud_init
}
