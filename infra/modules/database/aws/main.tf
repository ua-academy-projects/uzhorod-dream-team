locals {
  name     = "${var.config.prefix}-pg"
  database = var.config.database.managed
  tags     = { app = var.config.prefix, managed-by = "terraform" }
}

resource "aws_db_subnet_group" "pg" {
  name       = local.name
  subnet_ids = var.network.database_subnet_ids
  tags       = local.tags
}

resource "aws_security_group" "pg" {
  name        = local.name
  description = "PostgreSQL: only from the VMs"
  vpc_id      = var.network.network_id
  tags        = merge(local.tags, { Name = local.name })
}

resource "aws_vpc_security_group_ingress_rule" "pg_from_vms" {
  count                        = length(var.network.vm_firewall)
  security_group_id            = aws_security_group.pg.id
  referenced_security_group_id = var.network.vm_firewall[count.index]
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "pg" {
  identifier        = local.name
  engine            = "postgres"
  engine_version    = local.database.version
  instance_class    = var.size
  allocated_storage = local.database.disk_gb
  storage_type      = "gp3"
  storage_encrypted = true
  db_name           = var.config.app.db_name

  username                    = "postgres"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.pg.name
  vpc_security_group_ids = [aws_security_group.pg.id]
  availability_zone      = var.zone
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  backup_window           = "03:00-03:30"

  deletion_protection = local.database.deletion_protection
  apply_immediately   = true

  skip_final_snapshot = true

  tags = merge(local.tags, { Name = local.name })
}
