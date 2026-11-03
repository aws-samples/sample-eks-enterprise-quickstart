#!/usr/bin/env bash
# Discover existing VPC endpoints in <vpc_id> for region <region>.
#
# Output (JSON, on stdout) — schema fixed for terraform's `data "external"`:
#   {
#     "interface_services": "<csv of service shortnames in available/pendingAcceptance state>",
#     "s3_gateway_present": "true" | "false"
#   }
#
# Both values are strings (terraform external data source requires
# string values). Caller parses interface_services with split(",", ...)
# after handling the empty-string edge case.
#
# Why a shell wrapper:
#   - data.aws_vpc_endpoint (singular) throws when a filter matches zero
#     endpoints, which is exactly the "endpoint not yet created" case we
#     need to detect — using it here would force every brownfield apply
#     to provide a try() that downstream maps cannot reason about.
#   - The AWS Terraform provider does NOT expose a plural data source for
#     VPC endpoints (no aws_vpc_endpoints in v6.x).
#   - awscli is a hard requirement of every other workflow in this repo
#     (bootstrap-bastion ships it, README assumes it on operators), so a
#     shell-out is acceptable.

set -euo pipefail

USAGE="usage: list-vpc-endpoints.sh <vpc-id> <region> <cluster-name>"
VPC_ID="${1:?$USAGE}"
REGION="${2:?$USAGE}"
CLUSTER_NAME="${3:?$USAGE}"

# Pull every endpoint in the VPC (Interface + Gateway, all states).
# Filter to the "alive" subset client-side. --no-cli-pager so terraform
# captures pure JSON.
#
# Endpoints created by THIS stack are dropped here: otherwise the second
# plan sees them as pre-existing, removes them from the create set, and
# Terraform destroys every endpoint it owns. Ownership = the exact Name tag
# the module assigns ("<cluster>-<service>-endpoint" for Interface,
# "<cluster>-s3-gateway-endpoint" for the S3 Gateway).
ENDPOINTS_JSON=$(
  aws ec2 describe-vpc-endpoints \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,ServiceName,State,Tags]' \
    --output json \
  | jq --arg cluster "$CLUSTER_NAME" --arg prefix "com.amazonaws.${REGION}." '
      map(
        .[1] as $type
        | (.[2] | ltrimstr($prefix)) as $short
        | (.[4] // []) as $tags
        | (if $type == "Gateway" then ($cluster + "-s3-gateway-endpoint")
           else ($cluster + "-" + $short + "-endpoint") end) as $our_name
        | select(($tags | any(.Key == "Name" and .Value == $our_name)) | not)
        | .[0:4]
      )'
)

# Service-name prefix we care about (i.e. AWS-published services in this
# region, not customer-published or VPC Lattice services). Match via
# string comparison rather than splitting on dots because some service
# names (ecr.api / ecr.dkr / sagemaker.api) contain dots.
PREFIX="com.amazonaws.${REGION}."

# Build CSV of Interface service shortnames.
INTERFACE_CSV=$(
  jq -r --arg prefix "$PREFIX" '
    map(select(.[1] == "Interface" and (.[3] == "available" or .[3] == "pendingAcceptance")))
    | map(.[2])
    | map(select(startswith($prefix)))
    | map(sub("^"+$prefix; ""))
    | unique
    | join(",")
  ' <<< "$ENDPOINTS_JSON"
)

S3_GATEWAY_PRESENT=$(
  jq -r --arg svc "${PREFIX}s3" '
    any(.[]; .[1] == "Gateway" and .[2] == $svc and (.[3] == "available" or .[3] == "pendingAcceptance"))
  ' <<< "$ENDPOINTS_JSON"
)

# Emit terraform-compatible JSON (all string values).
jq -nc \
  --arg services "$INTERFACE_CSV" \
  --arg s3 "$S3_GATEWAY_PRESENT" \
  '{interface_services: $services, s3_gateway_present: $s3}'
