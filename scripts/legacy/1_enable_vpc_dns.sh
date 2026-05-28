#!/bin/bash
#
# Enable VPC DNS Settings for EKS
# This script enables DNS Support and DNS Hostnames which are required for VPC Endpoints
#

set -e
set -o pipefail
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Symbols
CHECK_MARK="✓"
CROSS_MARK="✗"
INFO="ℹ"

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../0_setup_env.sh"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Enable VPC DNS Settings for EKS                   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo "VPC ID: ${VPC_ID}"
echo "Region: ${AWS_REGION}"
echo ""

# Validate required variables
if [ -z "${VPC_ID}" ]; then
    echo -e "${RED}${CROSS_MARK} Error: VPC_ID is not set${NC}"
    exit 1
fi

if [ -z "${AWS_REGION}" ]; then
    echo -e "${RED}${CROSS_MARK} Error: AWS_REGION is not set${NC}"
    exit 1
fi

# Check if VPC exists
echo -e "${BLUE}${INFO} Checking VPC exists...${NC}"
VPC_EXISTS=$(aws ec2 describe-vpcs \
    --vpc-ids "${VPC_ID}" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null)

if [ "${VPC_EXISTS}" != "${VPC_ID}" ]; then
    echo -e "${RED}${CROSS_MARK} VPC ${VPC_ID} does not exist in region ${AWS_REGION}${NC}"
    exit 1
fi

echo -e "${GREEN}${CHECK_MARK} VPC ${VPC_ID} exists${NC}"
echo ""

# Check current DNS Support status
echo -e "${BLUE}${INFO} Checking current DNS settings...${NC}"
DNS_SUPPORT=$(aws ec2 describe-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --attribute enableDnsSupport \
    --query 'EnableDnsSupport.Value' \
    --output text 2>/dev/null)

DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --attribute enableDnsHostnames \
    --query 'EnableDnsHostnames.Value' \
    --output text 2>/dev/null)

echo "  DNS Support: ${DNS_SUPPORT}"
echo "  DNS Hostnames: ${DNS_HOSTNAMES}"
echo ""

# Enable DNS Support
echo -e "${YELLOW}Enabling DNS Support...${NC}"
if [ "${DNS_SUPPORT}" == "True" ] || [ "${DNS_SUPPORT}" == "true" ]; then
    echo -e "${GREEN}${CHECK_MARK} DNS Support is already enabled${NC}"
else
    aws ec2 modify-vpc-attribute \
        --vpc-id "${VPC_ID}" \
        --enable-dns-support \
        --no-cli-pager 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${CHECK_MARK} DNS Support enabled successfully${NC}"
    else
        echo -e "${RED}${CROSS_MARK} Failed to enable DNS Support${NC}"
        exit 1
    fi
fi

# Enable DNS Hostnames
echo -e "${YELLOW}Enabling DNS Hostnames...${NC}"
if [ "${DNS_HOSTNAMES}" == "True" ] || [ "${DNS_HOSTNAMES}" == "true" ]; then
    echo -e "${GREEN}${CHECK_MARK} DNS Hostnames is already enabled${NC}"
else
    aws ec2 modify-vpc-attribute \
        --vpc-id "${VPC_ID}" \
        --enable-dns-hostnames \
        --no-cli-pager 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${CHECK_MARK} DNS Hostnames enabled successfully${NC}"
    else
        echo -e "${RED}${CROSS_MARK} Failed to enable DNS Hostnames${NC}"
        exit 1
    fi
fi

echo ""

# Verify settings
echo -e "${BLUE}${INFO} Verifying DNS settings...${NC}"
VERIFY_DNS_SUPPORT=$(aws ec2 describe-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --attribute enableDnsSupport \
    --query 'EnableDnsSupport.Value' \
    --output text 2>/dev/null)

VERIFY_DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --attribute enableDnsHostnames \
    --query 'EnableDnsHostnames.Value' \
    --output text 2>/dev/null)

echo ""
if [ "${VERIFY_DNS_SUPPORT}" == "True" ] && [ "${VERIFY_DNS_HOSTNAMES}" == "True" ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  VPC DNS Settings Configuration: SUCCESS          ║${NC}"
    echo -e "${GREEN}║  ${CHECK_MARK} DNS Support: Enabled                              ║${NC}"
    echo -e "${GREEN}║  ${CHECK_MARK} DNS Hostnames: Enabled                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}${INFO} Your VPC is now ready for VPC Endpoints${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  VPC DNS Settings Configuration: FAILED           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "DNS Support: ${VERIFY_DNS_SUPPORT}"
    echo "DNS Hostnames: ${VERIFY_DNS_HOSTNAMES}"
    echo ""
    exit 1
fi
