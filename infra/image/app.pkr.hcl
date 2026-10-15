# The image the vote and result Auto Scaling groups launch: Ubuntu with Docker,
# the CloudWatch agent and the AWS CLI, installed by the same Ansible roles that
# configure the fixed hosts. Built in the account's default VPC, so a fresh
# deploy can bake before infra/main exists:
#   packer init infra/image && packer build infra/image

packer {
  required_version = ">= 1.16.1"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.8"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}

# Keep these equal to infra/main's variables of the same names.
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "martin-"
}

variable "owner" {
  type    = string
  default = "martin"
}

locals {
  tags = {
    Owner   = var.owner
    Project = "ironhack-project-1"
  }
}

# The same Canonical parameter infra/main/compute.tf reads.
data "amazon-parameterstore" "ubuntu" {
  name   = "/aws/service/canonical/ubuntu/server/26.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
  region = var.region
}

source "amazon-ebs" "app" {
  region        = var.region
  source_ami    = data.amazon-parameterstore.ubuntu.value
  instance_type = "t3.micro"
  ssh_username  = "ubuntu"

  ami_name        = "${var.name_prefix}app-{{timestamp}}"
  ami_description = "Ubuntu 26.04 with Docker, the CloudWatch agent and the AWS CLI for the voting app"

  # No subnet or VPC set: the plugin uses the default VPC. Its build instance
  # needs a public IP, and the temporary security group opens SSH to this
  # machine's public IP only (the default is 0.0.0.0/0).
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  # IMDSv2 on the build instance, and on every instance launched from the image.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  imds_support = "v2.0"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = 16
    encrypted             = true
    delete_on_termination = true
  }

  # Packer's temporary key leaves the image.
  ssh_clear_authorized_keys = true

  # The account is shared: tag the image, its snapshot, and everything the
  # build creates for a while (instance, volume, key pair, security group).
  tags            = merge(local.tags, { Name = "${var.name_prefix}app" })
  snapshot_tags   = merge(local.tags, { Name = "${var.name_prefix}app" })
  run_tags        = merge(local.tags, { Name = "${var.name_prefix}packer-build" })
  run_volume_tags = merge(local.tags, { Name = "${var.name_prefix}packer-build" })
}

build {
  sources = ["source.amazon-ebs.app"]

  provisioner "ansible" {
    playbook_file = "${path.root}/../../ansible/image.yml"
    user          = "ubuntu"
    # Connect straight to the build instance's public IP instead of through
    # Packer's local SSH proxy.
    use_proxy = false
    extra_arguments = [
      "-e", "name_prefix=${var.name_prefix}",
      "-e", "aws_region=${var.region}",
    ]
  }
}
