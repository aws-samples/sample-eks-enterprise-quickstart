output "endpoints_security_group_id" {
  value = aws_security_group.endpoints.id
}

output "interface_endpoint_ids" {
  value = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_gateway_endpoint_id" {
  value = aws_vpc_endpoint.s3_gateway.id
}
