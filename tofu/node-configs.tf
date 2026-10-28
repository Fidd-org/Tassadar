locals {
  bastion_config = {
    image = "ubuntu-24-04-x64"
    size  = "s-1vcpu-1gb"
  }

  flowerca_config = {
    image = "ubuntu-24-04-x64"
    size  = "s-2vcpu-4gb"
  }

  pxc_config = {
    image          = "ubuntu-24-04-x64"
    size           = "s-2vcpu-4gb"
    data_disk_size = 30
  }

  monitoring_configs = {
    prometheus = {
      image = "ubuntu-24-04-x64"
      size  = "s-1vcpu-2gb"
    }
    grafana = {
      image = "ubuntu-24-04-x64"
      size  = "s-1vcpu-2gb"
    }
  }

  pxc_nodes = toset(["pxc-1", "pxc-2", "pxc-3"])
}
