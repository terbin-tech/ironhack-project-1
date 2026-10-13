# One security group per tier. Terraform removes the allow-all egress rule AWS
# adds to new security groups, so every outbound flow below is declared.
# Security groups do not filter DNS, instance metadata or Amazon Time Sync.

locals {
  tiers = toset(["frontend", "backend", "db"])

  ingress_rules = {
    frontend_vote      = { sg = "frontend", port = 80, cidr = "0.0.0.0/0", peer = null, desc = "vote from the internet" }
    frontend_result    = { sg = "frontend", port = 8080, cidr = "0.0.0.0/0", peer = null, desc = "result from the internet" }
    frontend_ssh       = { sg = "frontend", port = 22, cidr = var.admin_cidr, peer = null, desc = "SSH from the admin only" }
    backend_redis      = { sg = "backend", port = 6379, cidr = null, peer = "frontend", desc = "Redis from vote" }
    backend_ssh        = { sg = "backend", port = 22, cidr = null, peer = "frontend", desc = "SSH through the bastion" }
    db_postgres_worker = { sg = "db", port = 5432, cidr = null, peer = "backend", desc = "Postgres from worker" }
    db_postgres_result = { sg = "db", port = 5432, cidr = null, peer = "frontend", desc = "Postgres from result" }
    db_ssh             = { sg = "db", port = 22, cidr = null, peer = "frontend", desc = "SSH through the bastion" }
  }

  # Every tier needs apt and Docker Hub.
  web_egress_rules = merge([
    for tier in local.tiers : {
      "${tier}_http"  = { sg = tier, port = 80, cidr = "0.0.0.0/0", peer = null, desc = "apt and image pulls" }
      "${tier}_https" = { sg = tier, port = 443, cidr = "0.0.0.0/0", peer = null, desc = "apt and image pulls" }
    }
  ]...)

  egress_rules = merge(local.web_egress_rules, {
    frontend_ssh_backend = { sg = "frontend", port = 22, cidr = null, peer = "backend", desc = "bastion hop to backend" }
    frontend_ssh_db      = { sg = "frontend", port = 22, cidr = null, peer = "db", desc = "bastion hop to db" }
    frontend_redis       = { sg = "frontend", port = 6379, cidr = null, peer = "backend", desc = "vote to Redis" }
    frontend_postgres    = { sg = "frontend", port = 5432, cidr = null, peer = "db", desc = "result to Postgres" }
    backend_postgres     = { sg = "backend", port = 5432, cidr = null, peer = "db", desc = "worker to Postgres" }
  })
}

resource "aws_security_group" "this" {
  for_each = local.tiers

  #checkov:skip=CKV2_AWS_5:false positive; each group is attached through aws_instance.this[each.key]

  name        = "${var.name_prefix}${each.key}-sg"
  description = "${each.key} tier of the voting app"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}${each.key}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_rules

  #checkov:skip=CKV_AWS_260:the vote page is public on port 80 by design; the load balancer add-on revisits this

  security_group_id            = aws_security_group.this[each.value.sg].id
  description                  = each.value.desc
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  cidr_ipv4                    = each.value.cidr
  referenced_security_group_id = each.value.peer == null ? null : aws_security_group.this[each.value.peer].id

  tags = {
    Name = "${var.name_prefix}${replace(each.key, "_", "-")}"
  }
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = local.egress_rules

  security_group_id            = aws_security_group.this[each.value.sg].id
  description                  = each.value.desc
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  cidr_ipv4                    = each.value.cidr
  referenced_security_group_id = each.value.peer == null ? null : aws_security_group.this[each.value.peer].id

  tags = {
    Name = "${var.name_prefix}${replace(each.key, "_", "-")}"
  }
}
