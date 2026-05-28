#!/bin/bash
#
# Create VPC Endpoints for EKS Cluster
# Supports two modes controlled by VPC_ENDPOINTS_MODE (set in .env):
#
#   full    - Create all 13 Interface Endpoints + 1 S3 Gateway (default for private clusters)
#             ~$210/month (2 AZs); all AWS traffic stays inside VPC
#
#   minimal - Create only the 4 endpoints required for node registration + S3 Gateway
#             (default for public clusters); ~$50/month (2 AZs)
#             Skipped endpoints: ecr.api, ecr.dkr, logs, autoscaling,
#             elasticloadbalancing, elasticfilesystem, ssm, ssmmessages, ec2messages
#

set -e
set -o pipefail
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../0_setup_env.sh"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Creating VPC Endpoints for EKS Cluster${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Cluster Mode:      ${CLUSTER_MODE}"
echo "Endpoints Mode:    ${VPC_ENDPOINTS_MODE}"
echo ""

# Validate required variables (minimum 2 AZs)
required_vars=(
    "VPC_ID"
    "PRIVATE_SUBNET_A"
    "PRIVATE_SUBNET_B"
    "AWS_REGION"
    "CLUSTER_NAME"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: ${var} is not set${NC}"
        exit 1
    fi
done

# Get VPC CIDR
VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "${VPC_ID}" \
    --query 'Vpcs[0].CidrBlock' \
    --output text)

echo "VPC ID: ${VPC_ID}"
echo "VPC CIDR: ${VPC_CIDR}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo ""

# Create security group for VPC endpoints
echo -e "${YELLOW}Creating security group for VPC endpoints...${NC}"
SG_ID=$(aws ec2 create-security-group \
    --group-name "${CLUSTER_NAME}-vpc-endpoints-sg" \
    --description "Security group for VPC endpoints" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${CLUSTER_NAME}-vpc-endpoints-sg" "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

# Guard against describe-security-groups returning the literal string "None"
# when no SG matches (--output text serialization). Without this guard the
# script would happily attach all subsequent endpoints to SG=None and exit 0,
# leaving an empty/broken VPC endpoint set.
if [ -z "${SG_ID}" ] || [ "${SG_ID}" = "None" ]; then
    echo -e "${RED}Error: failed to get or create security group '${CLUSTER_NAME}-vpc-endpoints-sg'${NC}" >&2
    echo -e "${RED}Check IAM permissions (ec2:CreateSecurityGroup) and VPC SG quota${NC}" >&2
    exit 1
fi

echo "Security Group ID: ${SG_ID}"

# Add ingress rule for HTTPS from VPC
aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp \
    --port 443 \
    --cidr "${VPC_CIDR}" \
    --no-cli-pager 2>/dev/null || echo "Ingress rule already exists"

# Tag security group
aws ec2 create-tags \
    --resources "${SG_ID}" \
    --tags "Key=Name,Value=${CLUSTER_NAME}-vpc-endpoints-sg" \
           "Key=Cluster,Value=${CLUSTER_NAME}" \
           "Key=business,Value=middleware" \
           "Key=resource,Value=eks" \
    --no-cli-pager 2>/dev/null || true

echo -e "${GREEN}✓ Security group created${NC}"
echo ""

# Define subnet IDs based on AZ_COUNT (supports 2-4 AZs)
SUBNET_IDS="${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B}"
if [ "${AZ_COUNT}" -ge 3 ] && [ -n "${PRIVATE_SUBNET_C}" ]; then
    SUBNET_IDS="${SUBNET_IDS} ${PRIVATE_SUBNET_C}"
fi
if [ "${AZ_COUNT}" -ge 4 ] && [ -n "${PRIVATE_SUBNET_D}" ]; then
    SUBNET_IDS="${SUBNET_IDS} ${PRIVATE_SUBNET_D}"
fi
echo "Using ${AZ_COUNT} AZs for VPC endpoints"

# -----------------------------------------------------------------------
# Define endpoint sets
#
# REQUIRED_ENDPOINTS: always created regardless of mode
#   - eks:       Nodes register with API Server via private DNS
#   - eks-auth:  Pod Identity token exchange (no public alternative)
#   - sts:       Pod Identity credential vending (high call volume)
#   - ec2:       EBS CSI Driver + nodeadm (K8s 1.34+), high call volume
#
# FULL_ONLY_ENDPOINTS: created only in 'full' mode
#   - ecr.api / ecr.dkr:       image pull — can go via NAT in public mode
#   - logs:                    CloudWatch Logs — has public endpoint
#   - autoscaling:             Cluster Autoscaler — can go via NAT
#   - elasticloadbalancing:    ALB Controller — can go via NAT
#   - elasticfilesystem:       EFS CSI — can go via NAT (optional component)
#   - ssm / ssmmessages / ec2messages: SSM — works via public endpoint
# -----------------------------------------------------------------------

declare -a REQUIRED_ENDPOINTS=(
    "eks:EKS API (node registration)"
    "eks-auth:EKS Auth (Pod Identity)"
    "sts:STS (Pod Identity credentials)"
    "ec2:EC2 + EBS CSI Driver"
)

declare -a FULL_ONLY_ENDPOINTS=(
    "ecr.api:ECR API"
    "ecr.dkr:ECR Docker"
    "logs:CloudWatch Logs"
    "autoscaling:Cluster Autoscaler"
    "elasticloadbalancing:AWS LB Controller"
    "elasticfilesystem:EFS CSI Driver"
    "ssm:Systems Manager Session Manager"
    "ssmmessages:Session Manager Messages"
    "ec2messages:EC2 Messages for SSM"
)

# Build the final list to create
declare -a INTERFACE_ENDPOINTS=("${REQUIRED_ENDPOINTS[@]}")
if [ "${VPC_ENDPOINTS_MODE}" = "full" ]; then
    INTERFACE_ENDPOINTS+=("${FULL_ONLY_ENDPOINTS[@]}")
fi

# Build a space-padded lookup of required services so we can abort on hard
# failures. Soft failures on FULL_ONLY endpoints are tolerated (they have
# public fallbacks via NAT), but a missing eks/eks-auth/sts/ec2 endpoint
# silently breaks node registration and is worth aborting on.
# Use a string instead of bash 4+ associative arrays for portability.
REQUIRED_SERVICES_LOOKUP=" "
for endpoint_info in "${REQUIRED_ENDPOINTS[@]}"; do
    IFS=':' read -r service _description <<< "${endpoint_info}"
    REQUIRED_SERVICES_LOOKUP="${REQUIRED_SERVICES_LOOKUP}${service} "
done

# -----------------------------------------------------------------------
# Create interface endpoints
# -----------------------------------------------------------------------
echo -e "${YELLOW}Creating interface endpoints (mode: ${VPC_ENDPOINTS_MODE})...${NC}"
for endpoint_info in "${INTERFACE_ENDPOINTS[@]}"; do
    IFS=':' read -r service description <<< "${endpoint_info}"
    service_name="com.amazonaws.${AWS_REGION}.${service}"

    echo -n "  Creating ${description} (${service})... "

    EXISTING_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" \
        --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
        --output text 2>/dev/null)

    if [ -n "${EXISTING_ENDPOINT}" ] && [ "${EXISTING_ENDPOINT}" != "None" ]; then
        echo -e "${YELLOW}already exists (${EXISTING_ENDPOINT})${NC}"
        continue
    fi

    # Capture stderr so we can surface the failure reason. Failures on
    # FULL_ONLY endpoints are tolerated (NAT fallback), but failures on a
    # REQUIRED endpoint are fatal — silently continuing leaves the cluster
    # unable to register nodes and the failure point becomes invisible
    # downstream in 4_install_eks_cluster.sh.
    ENDPOINT_OUTPUT=$(aws ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" \
        --service-name "${service_name}" \
        --vpc-endpoint-type Interface \
        --subnet-ids ${SUBNET_IDS} \
        --security-group-ids "${SG_ID}" \
        --private-dns-enabled \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${CLUSTER_NAME}-${service}-endpoint},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text 2>&1) && ENDPOINT_RC=0 || ENDPOINT_RC=$?

    if [ "${ENDPOINT_RC}" -eq 0 ] && [ -n "${ENDPOINT_OUTPUT}" ]; then
        echo -e "${GREEN}✓ created (${ENDPOINT_OUTPUT})${NC}"
    else
        echo -e "${RED}✗ failed${NC}"
        # Required endpoints have no public fallback; aborting here surfaces
        # the failure now instead of letting node registration time out later.
        if [[ "${REQUIRED_SERVICES_LOOKUP}" == *" ${service} "* ]]; then
            echo -e "${RED}REQUIRED endpoint '${service}' could not be created. Aborting.${NC}" >&2
            echo -e "${RED}AWS error: ${ENDPOINT_OUTPUT}${NC}" >&2
            exit 1
        fi
        echo -e "${YELLOW}  (skipping; not required — traffic will route via NAT)${NC}"
    fi
done

# Print skipped endpoints in minimal mode
if [ "${VPC_ENDPOINTS_MODE}" = "minimal" ]; then
    echo ""
    echo -e "${YELLOW}Skipped in minimal mode (traffic routes via NAT Gateway):${NC}"
    for endpoint_info in "${FULL_ONLY_ENDPOINTS[@]}"; do
        IFS=':' read -r service description <<< "${endpoint_info}"
        echo "  - ${description} (${service})"
    done
    echo ""
    echo "  To enable all endpoints, set VPC_ENDPOINTS_MODE=full in .env"
fi

echo ""

# -----------------------------------------------------------------------
# Create S3 Gateway Endpoint (always — Gateway type is free)
# -----------------------------------------------------------------------
echo -n "Creating S3 Gateway Endpoint (free, always created)... "
service_name="com.amazonaws.${AWS_REGION}.s3"

EXISTING_S3_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" \
    --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
    --output text 2>/dev/null)

if [ -n "${EXISTING_S3_ENDPOINT}" ] && [ "${EXISTING_S3_ENDPOINT}" != "None" ]; then
    echo -e "${YELLOW}already exists (${EXISTING_S3_ENDPOINT})${NC}"
else
    # Get private route table IDs (using PRIVATE_SUBNETS from 0_setup_env.sh)
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
                  "Name=association.subnet-id,Values=${PRIVATE_SUBNETS}" \
        --query 'RouteTables[*].RouteTableId' \
        --output text)

    S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" \
        --service-name "${service_name}" \
        --vpc-endpoint-type Gateway \
        --route-table-ids ${ROUTE_TABLE_IDS} \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${CLUSTER_NAME}-s3-gateway-endpoint},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text 2>/dev/null)

    if [ -n "${S3_ENDPOINT_ID}" ]; then
        echo -e "${GREEN}✓ created (${S3_ENDPOINT_ID})${NC}"
    else
        echo -e "${RED}✗ failed${NC}"
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}VPC Endpoints Creation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Summary
TOTAL_INTERFACE=${#INTERFACE_ENDPOINTS[@]}
TOTAL_GATEWAY=1
echo "Created: ${TOTAL_INTERFACE} interface endpoint(s) + ${TOTAL_GATEWAY} S3 gateway endpoint"
if [ "${VPC_ENDPOINTS_MODE}" = "minimal" ]; then
    echo "Skipped: ${#FULL_ONLY_ENDPOINTS[@]} interface endpoints (set VPC_ENDPOINTS_MODE=full to create all)"
fi
echo ""

# List all endpoints for this cluster
echo "VPC Endpoints for cluster '${CLUSTER_NAME}':"
aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
    --query 'VpcEndpoints[*].[VpcEndpointType,ServiceName,State,VpcEndpointId]' \
    --output table

echo ""
echo -e "${YELLOW}Note: It may take a few minutes for endpoints to become available.${NC}"
