terraform {
  required_version = ">= 1.6"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.3"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Local KVM on this machine. On a real on-prem site this would be
# vSphere, Proxmox or OpenStack, the rest of the project stays the same.
provider "libvirt" {
  uri = "qemu:///system"
}
