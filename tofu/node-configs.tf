locals {
  bastion_config = {
    image = "ubuntu-24-04-x64"
    size  = "s-1vcpu-1gb-intel"
  }

  flowerca_config = {
    image = "ubuntu-24-04-x64"
    size  = "s-2vcpu-4gb-intel"
  }

  pxc_config = {
    image          = "ubuntu-24-04-x64"
    size           = "s-1vcpu-2gb-intel"
    data_disk_size = 30
  }

  monitoring_configs = {
    prometheus = {
      image = "ubuntu-24-04-x64"
      size  = "s-1vcpu-2gb-intel"
    }
    grafana = {
      image = "ubuntu-24-04-x64"
      size  = "s-1vcpu-2gb-intel"
    }
  }

  pxc_nodes = toset(["pxc-1", "pxc-2", "pxc-3"])
}
