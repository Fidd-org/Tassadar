resource "digitalocean_droplet" "flowerca" {
  name       = "flowerca-1"
  image      = local.flowerca_config.image
  region     = var.region
  size       = local.flowerca_config.size
  vpc_uuid   = data.digitalocean_vpc.pxc.id
  ssh_keys   = [local.admin_ssh_key.fingerprint]
  monitoring = true
  tags       = [digitalocean_tag.flowerca.name]

  user_data = local.automation_cloud_init
}