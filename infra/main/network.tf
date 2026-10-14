# One AZ: public subnet for the frontend, the bastion and the NAT gateway,
# one private subnet each for the backend and the database.

data "aws_availability_zones" "available" {
  state = "available"

  # Pin the zone by name, so a zone AWS adds later can never change the one used.
  filter {
    name   = "zone-name"
    values = ["${var.region}a"]
  }
}

locals {
  az = data.aws_availability_zones.available.names[0]
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

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = local.az

  tags = {
    Name = "${var.name_prefix}public"
  }
}

resource "aws_subnet" "backend" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = local.az

  tags = {
    Name = "${var.name_prefix}backend"
  }
}

resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = local.az

  tags = {
    Name = "${var.name_prefix}db"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# Zonal NAT: this VPC has one AZ and a public subnet anyway, so the benefits
# of a regional NAT (several AZs, no public subnet) would not apply here.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.name_prefix}nat"
  }

  depends_on = [aws_internet_gateway.this]
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
  for_each = {
    backend = aws_subnet.backend.id
    db      = aws_subnet.db.id
  }

  subnet_id      = each.value
  route_table_id = aws_route_table.private.id
}
