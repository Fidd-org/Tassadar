locals {
  # No private keys or service credentials belong in cloud-init or OpenTofu state.
  automation_cloud_init = "#cloud-config\n${yamlencode({
    ssh_pwauth   = false
    disable_root = true
    users = [{
      name                = "ansible"
      shell               = "/bin/bash"
      lock_passwd         = true
      sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
      ssh_authorized_keys = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }]
    write_files = [{
      path        = "/etc/ssh/sshd_config.d/00-tassadar.conf"
      owner       = "root:root"
      permissions = "0644"
      content     = <<-EOT
        PermitRootLogin no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AuthenticationMethods publickey
        UseDNS no
      EOT
    }]
    runcmd = [
      ["/bin/sh", "-ec", "/usr/sbin/sshd -t; systemctl reload ssh"],
    ]
  })}"
}
