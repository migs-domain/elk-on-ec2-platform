output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ids" {
  value = aws_nat_gateway.this[*].id
}

output "internet_gateway_id" {
  value = aws_internet_gateway.this.id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}
