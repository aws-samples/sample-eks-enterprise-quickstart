output "endpoints_security_group_id" {
  description = "ID of the SG attached to Interface endpoints we created. Empty string when no Interface endpoint was created (because all wanted services were already present in the VPC)."
  value       = length(aws_security_group.endpoints) > 0 ? aws_security_group.endpoints[0].id : ""
}

output "interface_endpoint_ids" {
  description = "Map of service shortname → endpoint ID for Interface endpoints THIS module created. Pre-existing endpoints (skipped) are not included; query them via the AWS API or the interface_endpoints_skipped output below."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "interface_endpoints_skipped" {
  description = "Service shortnames we wanted but skipped because the VPC already had a matching Interface endpoint (brownfield reuse). For audit / debugging."
  value       = sort(tolist(local.interface_services_skipped))
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 Gateway endpoint we created, or empty string if a pre-existing one was found and reused."
  value       = length(aws_vpc_endpoint.s3_gateway) > 0 ? aws_vpc_endpoint.s3_gateway[0].id : ""
}

output "s3_gateway_endpoint_skipped" {
  description = "True when an existing S3 Gateway endpoint was found in this VPC and we skipped creating ours."
  value       = local.s3_gateway_exists
}
