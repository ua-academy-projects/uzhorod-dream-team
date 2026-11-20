locals {
  tags = { app = var.config.prefix, managed-by = "terraform" }
}

resource "aws_secretsmanager_secret" "secret" {
  for_each = toset(var.secrets)
  name     = "${var.config.prefix}-${each.key}"
  tags     = local.tags

  recovery_window_in_days = 0
}
