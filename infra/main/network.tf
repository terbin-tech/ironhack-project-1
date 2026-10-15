# Two zones. Public subnets hold the internet-facing hosts and the load
# balancer nodes; the app subnets hold the vote and result groups in
# both zones; backend and db stay in zone a. One regional NAT gateway gives
# every private subnet its egress.

data "aws_availability_zones" "available" {
  state = "available"

  # Pin the zones by name, so a zone AWS adds later can never change the ones used.
  filter {
    name   = "zone-name"
    values = ["${var.region}a", "${var.region}b"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.names) == 2
      error_message = "Zones ${var.region}a and ${var.region}b must both be available."
    }
  }
}

locals {
  # { a = "us-east-1a", b = "us-east-1b" }
  zones = { for name in data.aws_availability_zones.available.names : trimprefix(name, var.region) => name }

  app_subnets = {
    a = "10.0.11.0/24"
    b = "10.0.12.0/24"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}vpc"
  }
}

# Nothing uses the VPC's default security group; managing it with no rules
# removes the allow-all rules AWS gives it.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}default-sg"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}igw"
  }
}

# Zone a keeps its original address, so nothing that sits in it is replaced.
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = local.zones["a"]

  tags = {
    Name = "${var.name_prefix}public-a"
  }
}

# An ALB needs subnets in at least two zones.
resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = local.zones["b"]

  tags = {
    Name = "${var.name_prefix}public-b"
  }
}

resource "aws_subnet" "app" {
  for_each = local.app_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = local.zones[each.key]

  tags = {
    Name = "${var.name_prefix}app-${each.key}"
  }
}

resource "aws_subnet" "backend" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = local.zones["a"]

  tags = {
    Name = "${var.name_prefix}backend"
  }
}

resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = local.zones["a"]

  tags = {
    Name = "${var.name_prefix}db"
  }
}

# Regional NAT: with private subnets in two zones, one regional gateway keeps
# each zone's egress when the other zone fails, and needs no public subnet or
# Elastic IP of its own. In automatic mode it may take up to 60 minutes to
# expand into a new zone and serves that zone's traffic from another zone
# meanwhile.
resource "aws_nat_gateway" "this" {
  availability_mode = "regional"
  vpc_id            = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}nat"
  }

  depends_on = [aws_internet_gateway.this]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}private"
  }
}

resource "aws_route_table_association" "private" {
  for_each = merge(
    {
      backend = aws_subnet.backend.id
      db      = aws_subnet.db.id
    },
    { for zone, subnet in aws_subnet.app : "app-${zone}" => subnet.id },
  )

  subnet_id      = each.value
  route_table_id = aws_route_table.private.id
}
