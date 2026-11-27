output "identity" {
  description = "The IAM role the VM runs as"
  value       = aws_iam_role.vm.arn
}

output "internal_ip" {
  value = aws_instance.vm.private_ip
}

output "external_ip" {
  value = var.vm.bastion ? aws_instance.vm.public_ip : null
}

output "id" {
  description = "The instance, for the layers built on it (its id)"
  value       = aws_instance.vm.id
}
