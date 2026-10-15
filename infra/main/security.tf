# One security group per tier. Terraform removes the allow-all egress rule AWS
# adds to new security groups, so every outbound flow below is declared.
# Security groups do not filter DNS, instance metadata or Amazon Time Sync.

locals {
  tiers = toset(["bastion", "alb", "vote", "result", "backend", "db"])

  # Every tier but the load balancer needs apt, Docker Hub and the AWS APIs.
  host_tiers = setsubtract(local.tiers, ["alb"])

  ingress_rules = {
    alb_http           = { sg = "alb", port = 80, cidr = "0.0.0.0/0", peer = null, desc = "HTTP from the internet, redirected to HTTPS" }
    alb_https          = { sg = "alb", port = 443, cidr = "0.0.0.0/0", peer = null, desc = "HTTPS from the internet" }
    bastion_ssh        = { sg = "bastion", port = 22, cidr = var.admin_cidr, peer = null, desc = "SSH from the admin only" }
    vote_http          = { sg = "vote", port = 80, cidr = null, peer = "alb", desc = "vote from the load balancer" }
    vote_ssh           = { sg = "vote", port = 22, cidr = null, peer = "bastion", desc = "SSH through the bastion" }
    result_http        = { sg = "result", port = 80, cidr = null, peer = "alb", desc = "result from the load balancer" }
    result_ssh         = { sg = "result", port = 22, cidr = null, peer = "bastion", desc = "SSH through the bastion" }
    backend_redis      = { sg = "backend", port = 6379, cidr = null, peer = "vote", desc = "Redis from vote" }
    backend_ssh        = { sg = "backend", port = 22, cidr = null, peer = "bastion", desc = "SSH through the bastion" }
    db_postgres_worker = { sg = "db", port = 5432, cidr = null, peer = "backend", desc = "Postgres from worker" }
    db_postgres_result = { sg = "db", port = 5432, cidr = null, peer = "result", desc = "Postgres from result" }
    db_ssh             = { sg = "db", port = 22, cidr = null, peer = "bastion", desc = "SSH through the bastion" }
  }

  # Every host tier needs apt and Docker Hub.
  web_egress_rules = merge([
    for tier in local.host_tiers : {
      "${tier}_http"  = { sg = tier, port = 80, cidr = "0.0.0.0/0", peer = null, desc = "apt and image pulls" }
      "${tier}_https" = { sg = tier, port = 443, cidr = "0.0.0.0/0", peer = null, desc = "apt and image pulls" }
    }
  ]...)

  egress_rules = merge(local.web_egress_rules, {
    alb_vote            = { sg = "alb", port = 80, cidr = null, peer = "vote", desc = "load balancer to vote" }
    alb_result          = { sg = "alb", port = 80, cidr = null, peer = "result", desc = "load balancer to result" }
    bastion_ssh_vote    = { sg = "bastion", port = 22, cidr = null, peer = "vote", desc = "bastion hop to vote" }
    bastion_ssh_result  = { sg = "bastion", port = 22, cidr = null, peer = "result", desc = "bastion hop to result" }
    bastion_ssh_backend = { sg = "bastion", port = 22, cidr = null, peer = "backend", desc = "bastion hop to backend" }
    bastion_ssh_db      = { sg = "bastion", port = 22, cidr = null, peer = "db", desc = "bastion hop to db" }
    vote_redis          = { sg = "vote", port = 6379, cidr = null, peer = "backend", desc = "vote to Redis" }
    result_postgres     = { sg = "result", port = 5432, cidr = null, peer = "db", desc = "result to Postgres" }
    backend_postgres    = { sg = "backend", port = 5432, cidr = null, peer = "db", desc = "worker to Postgres" }
  })
}

resource "aws_security_group" "this" {
  for_each = local.tiers

  #checkov:skip=CKV2_AWS_5:false positive; groups are attached through aws_instance.this, the launch templates and the load balancer

  name        = "${var.name_prefix}${each.key}-sg"
  description = "${each.key} tier of the voting app"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}${each.key}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_rules

  #checkov:skip=CKV_AWS_260:the load balancer takes HTTP from the internet only to redirect it to HTTPS

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
