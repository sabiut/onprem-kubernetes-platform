output "nodes" {
  value = { for name, n in var.nodes : name => "${n.ip} (${n.role})" }
}

output "ssh" {
  value = "ssh -i .keys/id_ed25519 debian@<ip>"
}
