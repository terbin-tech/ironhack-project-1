# Hands the hosts to Ansible: an ssh_config that jumps through the bastion.

locals {
  ansible_dir      = abspath("${path.module}/../../ansible")
  known_hosts_path = "${local.ansible_dir}/known_hosts"
}

resource "local_file" "ssh_config" {
  filename        = "${local.ansible_dir}/ssh_config"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/ssh_config.tftpl", {
    bastion_ip    = aws_instance.this["bastion"].public_ip
    frontend_ip   = aws_instance.this["frontend"].private_ip
    backend_ip    = aws_instance.this["backend"].private_ip
    db_ip         = aws_instance.this["db"].private_ip
    identity_file = pathexpand(var.ssh_private_key_path)
    known_hosts   = local.known_hosts_path
  })
}

# New instances mean new host keys; start from an empty known_hosts so a
# private IP reused by a rebuilt host is accepted instead of refused.
resource "terraform_data" "known_hosts_reset" {
  triggers_replace = [for instance in aws_instance.this : instance.id]

  provisioner "local-exec" {
    command = ": > '${local.known_hosts_path}'"
  }

  # local_file.ssh_config creates the ansible directory the command writes into.
  depends_on = [local_file.ssh_config]
}
