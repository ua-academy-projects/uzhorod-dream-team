output "network_id" {
  description = "The VPC"
  value       = aws_vpc.vpc.id
}

output "subnet_id" {
  description = "The private subnet of the VMs"
  value       = aws_subnet.private.id
}

output "firewall" {
  description = "The security groups a VM gets"
  value       = { bastion = [aws_security_group.bastion.id], vm = [aws_security_group.vm.id] }
}

# AWS only

output "public_subnet_id" {
  description = "The bastion's subnet"
  value       = aws_subnet.public.id
}

output "private_route_table_id" {
  description = "Where the bastion adds 0.0.0.0/0 -> itself (NAT)"
  value       = aws_route_table.private.id
}

output "database_subnet_ids" {
  description = "Two private subnets in two zones, for the RDS subnet group"
  value       = [aws_subnet.private.id, aws_subnet.database.id]
}
