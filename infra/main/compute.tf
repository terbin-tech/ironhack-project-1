data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/26.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}ironhack-project-1"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# The fixed hosts Ansible configures. vote and result run in Auto Scaling groups (app.tf).
locals {
  instances = {
    bastion = { subnet_id = aws_subnet.public.id, type = "t3.micro", public = true }
    backend = { subnet_id = aws_subnet.backend.id, type = "t3.small", public = false }
    db      = { subnet_id = aws_subnet.db.id, type = "t3.micro", public = false }
  }
}

resource "aws_instance" "this" {
  for_each = local.instances

  #checkov:skip=CKV_AWS_88:the bastion is the only public instance, by design
  #checkov:skip=CKV_AWS_135:t3 instances are always EBS-optimized
  #checkov:skip=CKV_AWS_126:5-minute basic metrics are enough for an email alarm on these hosts

  # insecure_value: a public AMI id, so keep it readable in plan output.
  ami                         = data.aws_ssm_parameter.ubuntu.insecure_value
  instance_type               = each.value.type
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = [aws_security_group.this[each.key].id]
  key_name                    = aws_key_pair.this.key_name
  associate_public_ip_address = each.value.public
  iam_instance_profile        = aws_iam_instance_profile.ec2.name

  # Hop limit 1: only host processes (the CloudWatch agent, the Docker daemon's
  # awslogs driver) use the instance role; containers cannot reach it.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 16
    encrypted   = true
  }

  tags = {
    Name = "${var.name_prefix}${each.key}"
  }

  lifecycle {
    # Canonical publishes new images often; a new AMI must not replace running hosts.
    ignore_changes = [ami]
  }

  # Private hosts need their NAT route before Ansible runs apt.
  depends_on = [
    aws_route_table_association.private,
    aws_route_table_association.public,
    aws_route_table_association.public_b,
  ]
}
