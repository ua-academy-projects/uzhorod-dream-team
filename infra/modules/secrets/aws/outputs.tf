output "ids" {
  description = "secret (its config.json name) => its ARN in Secrets Manager"
  value       = { for name, secret in aws_secretsmanager_secret.secret : name => secret.arn }
}
