ephemeral "random_password" "service" {
  for_each = local.passwords

  length  = 32
  special = false
}
