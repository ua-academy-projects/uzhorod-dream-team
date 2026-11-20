locals {
  name = "${var.config.prefix}-${var.name}"
  tags = { app = var.config.prefix, vm = var.name, managed-by = "terraform" }

  subnet_cidr = var.vm.bastion ? var.network.public_subnet : var.network.subnet_cidr
  internal_ip = cidrhost(local.subnet_cidr, var.vm.host)

  bastion_user_data = templatefile("${path.module}/bastion.cloud-init.yaml.tftpl", {
    prefix          = var.config.prefix
    ssh_port        = var.config.ssh.bastion_port
    host_key_secret = "${var.config.prefix}-ssh-host-key"
    region          = var.region
    private_subnet  = var.network.subnet_cidr
  })
}

data "aws_ami" "os" {
  most_recent = true
  owners      = [var.vm.image.owner]

  filter {
    name   = "name"
    values = [var.vm.image.name]
  }
}

resource "aws_iam_role" "vm" {
  name = local.name
  tags = local.tags

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "role" {
  for_each   = toset(var.vm.roles)
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
}

resource "aws_iam_role_policy" "secrets" {
  count = length(var.secret_ids) > 0 ? 1 : 0
  name  = "read-own-secrets"
  role  = aws_iam_role.vm.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = values(var.secret_ids) }]
  })
}

resource "aws_iam_instance_profile" "vm" {
  name = local.name
  role = aws_iam_role.vm.name
  tags = local.tags
}

resource "aws_instance" "vm" {
  ami                    = data.aws_ami.os.id
  instance_type          = var.vm.size
  subnet_id              = var.vm.bastion ? var.subnets.public : var.subnets.private
  private_ip             = local.internal_ip
  vpc_security_group_ids = var.firewall
  iam_instance_profile   = aws_iam_instance_profile.vm.name

  source_dest_check = !var.vm.bastion

  user_data                   = var.vm.bastion ? local.bastion_user_data : null
  user_data_replace_on_change = true

  root_block_device {
    volume_type = var.vm.disk_type
    volume_size = var.vm.disk_gb
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags        = merge(local.tags, { Name = local.name })
  volume_tags = merge(local.tags, { Name = local.name })

  depends_on = [aws_iam_role_policy.secrets, aws_iam_role_policy_attachment.role]

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "external" {
  count    = var.vm.bastion ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.vm.id
  tags     = merge(local.tags, { Name = "${local.name}-external" })
}

resource "aws_route" "nat" {
  count                  = var.vm.bastion ? 1 : 0
  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.vm.primary_network_interface_id
}