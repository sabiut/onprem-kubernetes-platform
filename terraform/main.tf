locals {
  gateway = cidrhost(var.network_cidr, 1)
}

# ---------- SSH key Ansible will use ----------
resource "tls_private_key" "ansible" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.ansible.private_key_openssh
  filename        = "${path.module}/../.keys/id_ed25519"
  file_permission = "0600"
}

# ---------- Network ----------
resource "libvirt_network" "lab" {
  name      = "${var.project}-net"
  mode      = "nat"
  addresses = [var.network_cidr]
  autostart = true
  dhcp {
    enabled = false
  }
  dns {
    enabled = true
  }
}

# ---------- Disks ----------
resource "libvirt_volume" "base" {
  name   = "${var.project}-debian13-base.qcow2"
  pool   = "default"
  source = var.base_image_url
  format = "qcow2"
}

resource "libvirt_volume" "disk" {
  for_each       = var.nodes
  name           = "${var.project}-${each.key}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base.id
  size           = each.value.disk * 1024 * 1024 * 1024
  format         = "qcow2"
}

# ---------- cloud-init: hostname, user, SSH key, static IP ----------
resource "libvirt_cloudinit_disk" "init" {
  for_each = var.nodes
  name     = "${var.project}-${each.key}-init.iso"
  pool     = "default"
  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname   = each.key
    public_key = tls_private_key.ansible.public_key_openssh
  })
  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    ip      = each.value.ip
    prefix  = split("/", var.network_cidr)[1]
    gateway = local.gateway
  })
}

# ---------- VMs ----------
resource "libvirt_domain" "node" {
  for_each   = var.nodes
  name       = "${var.project}-${each.key}"
  memory     = each.value.memory
  vcpu       = each.value.vcpu
  cloudinit  = libvirt_cloudinit_disk.init[each.key].id
  autostart  = false
  qemu_agent = false

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id = libvirt_network.lab.id
    addresses  = [each.value.ip]
  }

  disk {
    volume_id = libvirt_volume.disk[each.key].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}

# ---------- Hand-off to Ansible: generate the inventory ----------
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventories/local/hosts.yml"
  content = templatefile("${path.module}/templates/hosts.yml.tftpl", {
    groups = {
      for role in distinct([for n in var.nodes : n.role]) :
      role => { for name, n in var.nodes : name => n.ip if n.role == role }
    }
    ssh_key = abspath("${path.module}/../.keys/id_ed25519")
  })
}
