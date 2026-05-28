#!/bin/bash
#
# EKS Network Environment Validation Script
# This script validates the network environment before deploying an EKS cluster
# It checks VPC configuration, subnets, VPC endpoints, and internet connectivity
#

set -e
set -o pipefail
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Symbols
CHECK_MARK="✓"
CROSS_MARK="✗"
WARNING="⚠"
INFO="ℹ"

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../0_setup_env.sh"

# Validation results
ERRORS=0
WARNINGS=0
PASSED=0

# Arrays to store results
declare -a ERROR_MESSAGES=()
declare -a WARNING_MESSAGES=()
declare -a INFO_MESSAGES=()

# Function to print section header
print_section() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

# Function to print success
print_success() {
    echo -e "${GREEN}${CHECK_MARK} $1${NC}"
    PASSED=$((PASSED + 1))
}

# Function to print error
print_error() {
    echo -e "${RED}${CROSS_MARK} $1${NC}"
    ERROR_MESSAGES+=("$1")
    ERRORS=$((ERRORS + 1))
}

# Function to print warning
print_warning() {
    echo -e "${YELLOW}${WARNING} $1${NC}"
    WARNING_MESSAGES+=("$1")
    WARNINGS=$((WARNINGS + 1))
}

# Function to print info
print_info() {
    echo -e "${BLUE}${INFO} $1${NC}"
    INFO_MESSAGES+=("$1")
}

# Header
# clear command removed for compatibility
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  EKS Network Environment Validation Script         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Cluster Name: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo "VPC ID: ${VPC_ID}"
echo ""

# Validate required variables
print_section "1. Validating Environment Variables"

required_vars=(
    "VPC_ID"
    "PRIVATE_SUBNET_A"
    "PRIVATE_SUBNET_B"
    "PUBLIC_SUBNET_A"
    "PUBLIC_SUBNET_B"
    "AWS_REGION"
    "CLUSTER_NAME"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Environment variable ${var} is not set"
    else
        print_success "Environment variable ${var} is set: ${!var}"
    fi
done

# Validate VPC Configuration
print_section "2. Validating VPC Configuration"

# Check VPC exists
VPC_INFO=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --output json 2>&1)
if [ $? -eq 0 ]; then
    print_success "VPC ${VPC_ID} exists"

    VPC_CIDR=$(echo "${VPC_INFO}" | jq -r '.Vpcs[0].CidrBlock')
    print_info "VPC CIDR: ${VPC_CIDR}"

    # Check DNS configuration - must use describe-vpc-attribute
    DNS_SUPPORT=$(aws ec2 describe-vpc-attribute --vpc-id "${VPC_ID}" --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text 2>/dev/null)
    DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute --vpc-id "${VPC_ID}" --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text 2>/dev/null)

    if [ "${DNS_SUPPORT}" == "True" ] || [ "${DNS_SUPPORT}" == "true" ]; then
        print_success "DNS Support is enabled"
    else
        print_error "DNS Support is NOT enabled (required for VPC endpoints)"
    fi

    if [ "${DNS_HOSTNAMES}" == "True" ] || [ "${DNS_HOSTNAMES}" == "true" ]; then
        print_success "DNS Hostnames is enabled"
    else
        print_error "DNS Hostnames is NOT enabled (required for VPC endpoints)"
    fi
else
    print_error "VPC ${VPC_ID} does not exist or access denied"
fi

# Validate Subnets
print_section "3. Validating Subnets"

# Build subnet arrays based on AZ_COUNT (supports 2-4 AZs)
PRIVATE_SUBNET_LIST=("${PRIVATE_SUBNET_A}" "${PRIVATE_SUBNET_B}")
AZ_LIST=("${AZ_A}" "${AZ_B}")
if [ "${AZ_COUNT}" -ge 3 ] && [ -n "${PRIVATE_SUBNET_C}" ]; then
    PRIVATE_SUBNET_LIST+=("${PRIVATE_SUBNET_C}")
    AZ_LIST+=("${AZ_C}")
fi
if [ "${AZ_COUNT}" -ge 4 ] && [ -n "${PRIVATE_SUBNET_D}" ]; then
    PRIVATE_SUBNET_LIST+=("${PRIVATE_SUBNET_D}")
    AZ_LIST+=("${AZ_D}")
fi

echo -e "${BLUE}Private Subnets:${NC}"
for i in "${!PRIVATE_SUBNET_LIST[@]}"; do
    SUBNET_ID="${PRIVATE_SUBNET_LIST[$i]}"
    EXPECTED_AZ="${AZ_LIST[$i]}"

    SUBNET_INFO=$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" --output json 2>&1)
    if [ $? -eq 0 ]; then
        SUBNET_CIDR=$(echo "${SUBNET_INFO}" | jq -r '.Subnets[0].CidrBlock')
        SUBNET_AZ=$(echo "${SUBNET_INFO}" | jq -r '.Subnets[0].AvailabilityZone')
        AVAILABLE_IPS=$(echo "${SUBNET_INFO}" | jq -r '.Subnets[0].AvailableIpAddressCount')

        print_success "Subnet ${SUBNET_ID} exists (${SUBNET_CIDR}, AZ: ${SUBNET_AZ}, Available IPs: ${AVAILABLE_IPS})"

        # Check AZ matches
        if [ "${SUBNET_AZ}" != "${EXPECTED_AZ}" ]; then
            print_warning "Subnet ${SUBNET_ID} is in ${SUBNET_AZ}, expected ${EXPECTED_AZ}"
        fi

        # Check available IPs
        if [ "${AVAILABLE_IPS}" -lt 50 ]; then
            print_warning "Subnet ${SUBNET_ID} has only ${AVAILABLE_IPS} available IPs (recommend at least 50)"
        fi
    else
        print_error "Subnet ${SUBNET_ID} does not exist or access denied"
    fi
done

echo ""
echo -e "${BLUE}Public Subnets:${NC}"
# Build public subnet array based on AZ_COUNT
PUBLIC_SUBNET_LIST=("${PUBLIC_SUBNET_A}" "${PUBLIC_SUBNET_B}")
if [ "${AZ_COUNT}" -ge 3 ] && [ -n "${PUBLIC_SUBNET_C}" ]; then
    PUBLIC_SUBNET_LIST+=("${PUBLIC_SUBNET_C}")
fi
if [ "${AZ_COUNT}" -ge 4 ] && [ -n "${PUBLIC_SUBNET_D}" ]; then
    PUBLIC_SUBNET_LIST+=("${PUBLIC_SUBNET_D}")
fi

for i in "${!PUBLIC_SUBNET_LIST[@]}"; do
    SUBNET_ID="${PUBLIC_SUBNET_LIST[$i]}"
    EXPECTED_AZ="${AZ_LIST[$i]}"

    SUBNET_INFO=$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" --output json 2>&1)
    if [ $? -eq 0 ]; then
        SUBNET_CIDR=$(echo "${SUBNET_INFO}" | jq -r '.Subnets[0].CidrBlock')
        SUBNET_AZ=$(echo "${SUBNET_INFO}" | jq -r '.Subnets[0].AvailabilityZone')
        MAP_PUBLIC_IP=$(echo "${SUBNET_INFO}" | jq -r '.Subnets[0].MapPublicIpOnLaunch')

        print_success "Subnet ${SUBNET_ID} exists (${SUBNET_CIDR}, AZ: ${SUBNET_AZ})"

        # Check if auto-assign public IP is enabled
        if [ "${MAP_PUBLIC_IP}" == "true" ]; then
            print_info "Auto-assign public IP is enabled for ${SUBNET_ID}"
        else
            print_warning "Auto-assign public IP is disabled for ${SUBNET_ID}"
        fi

        # Check AZ matches
        if [ "${SUBNET_AZ}" != "${EXPECTED_AZ}" ]; then
            print_warning "Subnet ${SUBNET_ID} is in ${SUBNET_AZ}, expected ${EXPECTED_AZ}"
        fi
    else
        print_error "Subnet ${SUBNET_ID} does not exist or access denied"
    fi
done

# Validate Route Tables and NAT Gateways
print_section "4. Validating Route Tables and NAT Gateways"

# Check Internet Gateway
echo -e "${BLUE}Internet Gateway:${NC}"
IGW_INFO=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --output json 2>&1)

if [ $? -eq 0 ]; then
    IGW_ID=$(echo "${IGW_INFO}" | jq -r '.InternetGateways[0].InternetGatewayId')
    if [ "${IGW_ID}" != "null" ] && [ -n "${IGW_ID}" ]; then
        print_success "Internet Gateway ${IGW_ID} is attached to VPC"
    else
        print_error "No Internet Gateway attached to VPC (required for public subnets)"
    fi
else
    print_error "Failed to query Internet Gateways"
fi

echo ""
echo -e "${BLUE}NAT Gateways:${NC}"
NAT_INFO=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
    --output json 2>&1)

if [ $? -eq 0 ]; then
    NAT_COUNT=$(echo "${NAT_INFO}" | jq '.NatGateways | length')

    if [ "${NAT_COUNT}" -eq 0 ]; then
        print_error "No NAT Gateways found (required for private subnet internet access)"
    elif [ "${NAT_COUNT}" -eq 1 ]; then
        NAT_ID=$(echo "${NAT_INFO}" | jq -r '.NatGateways[0].NatGatewayId')
        NAT_SUBNET=$(echo "${NAT_INFO}" | jq -r '.NatGateways[0].SubnetId')
        print_warning "Only 1 NAT Gateway found (${NAT_ID} in ${NAT_SUBNET}). Recommend 3 for high availability."
    elif [ "${NAT_COUNT}" -eq 3 ]; then
        print_success "${NAT_COUNT} NAT Gateways found (high availability configuration)"
        echo "${NAT_INFO}" | jq -r '.NatGateways[] | "  - \(.NatGatewayId) in \(.SubnetId)"'
    else
        print_success "${NAT_COUNT} NAT Gateways found"
        echo "${NAT_INFO}" | jq -r '.NatGateways[] | "  - \(.NatGatewayId) in \(.SubnetId)"'
    fi
else
    print_error "Failed to query NAT Gateways"
fi

echo ""
echo -e "${BLUE}Private Subnet Route Tables:${NC}"
for SUBNET_ID in "${PRIVATE_SUBNET_LIST[@]}"; do
    RT_INFO=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
        --output json 2>&1)

    if [ $? -eq 0 ]; then
        RT_ID=$(echo "${RT_INFO}" | jq -r '.RouteTables[0].RouteTableId')

        # Check for default route to NAT Gateway
        NAT_ROUTE=$(echo "${RT_INFO}" | jq -r '.RouteTables[0].Routes[] | select(.DestinationCidrBlock=="0.0.0.0/0") | .NatGatewayId')

        if [ "${NAT_ROUTE}" != "null" ] && [ -n "${NAT_ROUTE}" ]; then
            print_success "Subnet ${SUBNET_ID} has route to NAT Gateway ${NAT_ROUTE}"
        else
            print_error "Subnet ${SUBNET_ID} does NOT have route to NAT Gateway (no internet access)"
        fi
    else
        print_warning "Failed to query route table for subnet ${SUBNET_ID}"
    fi
done

# Validate VPC Endpoints
print_section "5. Validating VPC Endpoints"

# Required endpoints for private EKS cluster
declare -A REQUIRED_ENDPOINTS=(
    ["eks"]="EKS API"
    ["eks-auth"]="EKS Auth (Pod Identity)"
    ["sts"]="STS (Pod Identity)"
    ["ecr.api"]="ECR API"
    ["ecr.dkr"]="ECR Docker"
    ["logs"]="CloudWatch Logs"
    ["s3"]="S3 (Gateway)"
)

declare -A RECOMMENDED_ENDPOINTS=(
    ["ec2"]="EC2 + EBS CSI"
    ["autoscaling"]="Cluster Autoscaler"
    ["elasticloadbalancing"]="AWS LB Controller"
    ["elasticfilesystem"]="EFS CSI Driver"
)

echo -e "${BLUE}Required VPC Endpoints (7):${NC}"
MISSING_REQUIRED=0

for service in "${!REQUIRED_ENDPOINTS[@]}"; do
    description="${REQUIRED_ENDPOINTS[$service]}"
    service_name="com.amazonaws.${AWS_REGION}.${service}"

    if [ "${service}" == "s3" ]; then
        # S3 is a gateway endpoint
        ENDPOINT_INFO=$(aws ec2 describe-vpc-endpoints \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" "Name=vpc-endpoint-type,Values=Gateway" \
            --query 'VpcEndpoints[0]' \
            --output json 2>&1)
    else
        # Interface endpoints
        ENDPOINT_INFO=$(aws ec2 describe-vpc-endpoints \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" "Name=vpc-endpoint-type,Values=Interface" \
            --query 'VpcEndpoints[0]' \
            --output json 2>&1)
    fi

    ENDPOINT_ID=$(echo "${ENDPOINT_INFO}" | jq -r '.VpcEndpointId' 2>/dev/null)
    ENDPOINT_STATE=$(echo "${ENDPOINT_INFO}" | jq -r '.State' 2>/dev/null)

    if [ "${ENDPOINT_ID}" != "null" ] && [ -n "${ENDPOINT_ID}" ] && [ "${ENDPOINT_ID}" != "" ]; then
        if [ "${ENDPOINT_STATE}" == "available" ]; then
            print_success "${description}: ${ENDPOINT_ID} (${ENDPOINT_STATE})"
        else
            print_warning "${description}: ${ENDPOINT_ID} (${ENDPOINT_STATE})"
        fi
    else
        print_error "${description} endpoint NOT found (${service_name})"
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    fi
done

echo ""
echo -e "${BLUE}Recommended VPC Endpoints (4):${NC}"
MISSING_RECOMMENDED=0

for service in "${!RECOMMENDED_ENDPOINTS[@]}"; do
    description="${RECOMMENDED_ENDPOINTS[$service]}"
    service_name="com.amazonaws.${AWS_REGION}.${service}"

    ENDPOINT_INFO=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" \
        --query 'VpcEndpoints[0]' \
        --output json 2>&1)

    ENDPOINT_ID=$(echo "${ENDPOINT_INFO}" | jq -r '.VpcEndpointId' 2>/dev/null)
    ENDPOINT_STATE=$(echo "${ENDPOINT_INFO}" | jq -r '.State' 2>/dev/null)

    if [ "${ENDPOINT_ID}" != "null" ] && [ -n "${ENDPOINT_ID}" ] && [ "${ENDPOINT_ID}" != "" ]; then
        if [ "${ENDPOINT_STATE}" == "available" ]; then
            print_success "${description}: ${ENDPOINT_ID} (${ENDPOINT_STATE})"
        else
            print_warning "${description}: ${ENDPOINT_ID} (${ENDPOINT_STATE})"
        fi
    else
        print_warning "${description} endpoint NOT found (${service_name})"
        MISSING_RECOMMENDED=$((MISSING_RECOMMENDED + 1))
    fi
done

if [ ${MISSING_REQUIRED} -gt 0 ]; then
    echo ""
    print_error "${MISSING_REQUIRED} required VPC endpoints are missing"
    print_info "Run './scripts/legacy/3_create_vpc_endpoints.sh' to create missing endpoints"
fi

if [ ${MISSING_RECOMMENDED} -gt 0 ]; then
    echo ""
    print_warning "${MISSING_RECOMMENDED} recommended VPC endpoints are missing"
    print_info "These endpoints are needed for Cluster Autoscaler, AWS LB Controller, and CSI drivers"
fi

# Validate Security Groups for VPC Endpoints
print_section "6. Validating VPC Endpoint Security Groups"

# Get security groups used by VPC endpoints
ENDPOINT_SG_IDS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=vpc-endpoint-type,Values=Interface" \
    --query 'VpcEndpoints[].Groups[].GroupId' \
    --output json 2>&1 | jq -r '.[] | select(. != null)' | sort -u)

if [ -n "${ENDPOINT_SG_IDS}" ]; then
    for SG_ID in ${ENDPOINT_SG_IDS}; do
        SG_INFO=$(aws ec2 describe-security-groups --group-ids "${SG_ID}" --output json 2>&1)

        if [ $? -eq 0 ]; then
            SG_NAME=$(echo "${SG_INFO}" | jq -r '.SecurityGroups[0].GroupName')

            # Check if security group allows HTTPS (port 443) from VPC
            HTTPS_RULE=$(echo "${SG_INFO}" | jq -r '.SecurityGroups[0].IpPermissions[] | select(.FromPort==443 and .ToPort==443)')

            if [ -n "${HTTPS_RULE}" ]; then
                print_success "Security Group ${SG_ID} (${SG_NAME}) allows HTTPS (443)"
            else
                print_error "Security Group ${SG_ID} (${SG_NAME}) does NOT allow HTTPS (443)"
            fi
        fi
    done
else
    print_info "No VPC endpoint security groups found (no interface endpoints)"
fi

# Summary Report
print_section "7. Validation Summary"

echo -e "${GREEN}Passed Checks: ${PASSED}${NC}"
echo -e "${YELLOW}Warnings: ${WARNINGS}${NC}"
echo -e "${RED}Failed Checks: ${ERRORS}${NC}"
echo ""

if [ ${ERRORS} -gt 0 ]; then
    echo -e "${RED}Critical Issues Found:${NC}"
    for msg in "${ERROR_MESSAGES[@]}"; do
        echo -e "  ${RED}${CROSS_MARK}${NC} ${msg}"
    done
    echo ""
fi

if [ ${WARNINGS} -gt 0 ]; then
    echo -e "${YELLOW}Warnings:${NC}"
    for msg in "${WARNING_MESSAGES[@]}"; do
        echo -e "  ${YELLOW}${WARNING}${NC} ${msg}"
    done
    echo ""
fi

# Recommendations
print_section "8. Recommendations"

if [ ${MISSING_REQUIRED} -gt 0 ]; then
    echo -e "${RED}[CRITICAL]${NC} Create required VPC endpoints:"
    echo "  ./scripts/legacy/3_create_vpc_endpoints.sh"
    echo ""
fi

if [ ${MISSING_RECOMMENDED} -gt 0 ]; then
    echo -e "${YELLOW}[RECOMMENDED]${NC} Create recommended VPC endpoints for full functionality"
    echo ""
fi

if [ ${ERRORS} -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Network Environment Validation: PASSED            ║${NC}"
    echo -e "${GREEN}║  You can proceed with EKS cluster deployment       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Network Environment Validation: FAILED            ║${NC}"
    echo -e "${RED}║  Please fix the errors before deploying EKS        ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
