ephemeral "random_password" "service" {
  for_each = var.config.passwords

  length  = 32
  special = false
}
