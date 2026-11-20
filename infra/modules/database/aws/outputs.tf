output "address" {
  description = "The instance's host name inside our VPC (RDS gives a name, not a fixed IP)"
  value       = aws_db_instance.pg.address
}
