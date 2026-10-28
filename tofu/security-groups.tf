resource "digitalocean_firewall" "bastion" {
  name = "${var.name_prefix}-bastion-firewall"
  tags = [digitalocean_tag.bastion.name]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.admin_cidr]
  }

  # Reserved for node_exporter; installed separately by Ansible.
  inbound_rule {
    protocol    = "tcp"
    port_range  = "9100"
    source_tags = [digitalocean_tag.monitoring["prometheus"].name]
  }

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

resource "digitalocean_firewall" "flowerca" {
  name = "flowerca-firewall"
  tags = [digitalocean_tag.flowerca.name]

  inbound_rule {
    protocol    = "tcp"
    port_range  = "22"
    source_tags = [digitalocean_tag.bastion.name]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Reserved for node_exporter; installed separately by Ansible.
  inbound_rule {
    protocol    = "tcp"
    port_range  = "9100"
    source_tags = [digitalocean_tag.monitoring["prometheus"].name]
  }

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

resource "digitalocean_firewall" "pxc" {
  name = "${var.name_prefix}-nodes-firewall"
  tags = [digitalocean_tag.pxc.name]

  inbound_rule {
    protocol    = "tcp"
    port_range  = "22"
    source_tags = [digitalocean_tag.bastion.name]
  }

  inbound_rule {
    protocol   = "tcp"
    port_range = "3306"
    source_tags = [
      digitalocean_tag.bastion.name,
      digitalocean_tag.flowerca.name,
    ]
  }

  inbound_rule {
    protocol    = "tcp"
    port_range  = "4444"
    source_tags = [digitalocean_tag.pxc.name]
  }

  inbound_rule {
    protocol    = "tcp"
    port_range  = "4567-4568"
    source_tags = [digitalocean_tag.pxc.name]
  }

  inbound_rule {
    protocol    = "udp"
    port_range  = "4567"
    source_tags = [digitalocean_tag.pxc.name]
  }

  # mysqld_exporter connects to MySQL locally; Prometheus only reaches its metrics.
  inbound_rule {
    protocol    = "tcp"
    port_range  = "9104"
    source_tags = [digitalocean_tag.monitoring["prometheus"].name]
  }

  # Reserved for node_exporter; installed separately by Ansible.
  inbound_rule {
    protocol    = "tcp"
    port_range  = "9100"
    source_tags = [digitalocean_tag.monitoring["prometheus"].name]
  }

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

resource "digitalocean_firewall" "prometheus" {
  name = "${var.name_prefix}-prometheus-firewall"
  tags = [digitalocean_tag.monitoring["prometheus"].name]

  inbound_rule {
    protocol    = "tcp"
    port_range  = "22"
    source_tags = [digitalocean_tag.bastion.name]
  }

  inbound_rule {
    protocol    = "tcp"
    port_range  = "9090"
    source_tags = [digitalocean_tag.monitoring["grafana"].name, digitalocean_tag.bastion.name]
  }

  # Reserved for node_exporter; installed separately by Ansible.
  inbound_rule {
    protocol    = "tcp"
    port_range  = "9100"
    source_tags = [digitalocean_tag.monitoring["prometheus"].name]
  }

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

resource "digitalocean_firewall" "grafana" {
  name = "${var.name_prefix}-grafana-firewall"
  tags = [digitalocean_tag.monitoring["grafana"].name]

  inbound_rule {
    protocol    = "tcp"
    port_range  = "22"
    source_tags = [digitalocean_tag.bastion.name]
  }

  inbound_rule {
    protocol    = "tcp"
    port_range  = "3000"
    source_tags = [digitalocean_tag.bastion.name]
  }

  # Reserved for node_exporter; installed separately by Ansible.
  inbound_rule {
    protocol    = "tcp"
    port_range  = "9100"
    source_tags = [digitalocean_tag.monitoring["prometheus"].name]
  }

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
