variable "project" {
  type    = string
  default = "k8slab"
}

variable "base_image_url" {
  description = "Debian 13 cloud image"
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "network_cidr" {
  type    = string
  default = "10.17.0.0/24"
}

# Kept small: this machine has limited free RAM.
variable "nodes" {
  description = "VMs to create. role becomes the Ansible group."
  type = map(object({
    role   = string
    ip     = string
    memory = number # MB
    vcpu   = number
    disk   = number # GB
  }))
  default = {
    k8s-cp1 = { role = "k3s_server", ip = "10.17.0.10", memory = 2048, vcpu = 2, disk = 15 }
    k8s-w1  = { role = "k3s_agents", ip = "10.17.0.21", memory = 3072, vcpu = 2, disk = 15 }
    db1     = { role = "dbservers", ip = "10.17.0.30", memory = 1024, vcpu = 1, disk = 10 }
  }
}
