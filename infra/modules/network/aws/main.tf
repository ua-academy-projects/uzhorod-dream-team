
locals {
  name = "${var.config.prefix}-vpc"
  tags = { app = var.config.prefix, managed-by = "terraform" }

  internal_ports = distinct(concat(var.config.network.internal_ports, var.config.database.type == "vm" ? ["5432"] : []))
  vm_cidrs       = concat([var.network.subnet_cidr], var.peer_cidrs) # our VMs, and the other clouds' (through the bastions)
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.network.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })

  lifecycle {
    precondition {
      condition     = var.account_id != ""
      error_message = "config.json puts something in AWS, but AWS is not set up: put AWS_ADMIN_PROFILE in infra/bootstrap/bootstrap.env, run bootstrap.sh, source terraform.env."
    }
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags   = merge(local.tags, { Name = local.name })
}


resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = var.network.public_subnet
  availability_zone = var.zone
  tags              = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = var.network.subnet_cidr
  availability_zone = var.zone
  tags              = merge(local.tags, { Name = "${local.name}-private" })
}

resource "aws_subnet" "database" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = var.network.database_subnet
  availability_zone = var.database_zone
  tags              = merge(local.tags, { Name = "${local.name}-database" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  tags   = merge(local.tags, { Name = "${local.name}-public" })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id
  tags   = merge(local.tags, { Name = "${local.name}-private" })
}

resource "aws_route_table_association" "private" {
  for_each       = { private = aws_subnet.private.id, database = aws_subnet.database.id }
  subnet_id      = each.value
  route_table_id = aws_route_table.private.id
}

# firewall: one security group for the bastion, one for every other VM

resource "aws_security_group" "bastion" {
  name        = "${local.name}-bastion"
  description = "Bastion: SSH from you, and the traffic of the private subnet it forwards (NAT)"
  vpc_id      = aws_vpc.vpc.id
  tags        = merge(local.tags, { Name = "${local.name}-bastion" })
}

resource "aws_vpc_security_group_ingress_rule" "ssh_to_bastion" {
  for_each          = toset(var.ssh_allowed_cidrs)
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = var.config.ssh.bastion_port
  to_port           = var.config.ssh.bastion_port
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_private" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = var.network.subnet_cidr
  ip_protocol       = "-1"
}

resource "aws_security_group" "vm" {
  name        = "${local.name}-vm"
  description = "Every VM but the bastion: SSH from the bastion, service ports from the VMs"
  vpc_id      = aws_vpc.vpc.id
  tags        = merge(local.tags, { Name = "${local.name}-vm" })
}

resource "aws_vpc_security_group_ingress_rule" "ssh_from_bastion" {
  security_group_id            = aws_security_group.vm.id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

# VM <-> VM, in this cloud and from the other clouds (through the bastions): only the services' ports
resource "aws_vpc_security_group_ingress_rule" "internal" {
  for_each          = { for pair in setproduct(local.vm_cidrs, local.internal_ports) : "${pair[0]}/${pair[1]}" => { cidr = pair[0], port = pair[1] } }
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value.port)
  to_port           = tonumber(each.value.port)
}

resource "aws_vpc_security_group_ingress_rule" "icmp" {
  for_each          = toset(local.vm_cidrs)
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.key
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each          = { bastion = aws_security_group.bastion.id, vm = aws_security_group.vm.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
