terraform {
  required_version = ">= 1.8"

  required_providers {
    # Retained while older local_file inventory state is being forgotten.
    local = {
      source = "hashicorp/local"
    }

    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}
