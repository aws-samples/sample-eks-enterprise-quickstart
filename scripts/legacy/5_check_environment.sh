#!/bin/bash
#
# 4_check_environment.sh - Check if current environment can replace bastion host
#
# This script validates whether the current machine has the necessary
# tools, network access, and AWS permissions to operate an EKS cluster.
#

set -e
set -o pipefail
export AWS_PAGER=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASS=0
FAIL=0
WARN=0

# Functions
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

check_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    ((PASS++)) || true
}

check_fail() {
    echo -e "  ${RED}✗${NC} $1"
    ((FAIL++)) || true
}

check_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    ((WARN++)) || true
}

check_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#######################################
# 1. Required Tools Check
#######################################
print_header "1. Required Tools"

# kubectl
if command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || kubectl version --client 2>/dev/null | head -1)
    check_pass "kubectl installed: ${KUBECTL_VERSION}"
else
    check_fail "kubectl not installed"
fi

# aws cli
if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d' ' -f1)
    check_pass "aws cli installed: ${AWS_VERSION}"
else
    check_fail "aws cli not installed"
fi

# helm
if command -v helm &> /dev/null; then
    HELM_VERSION=$(helm version --short 2>/dev/null)
    check_pass "helm installed: ${HELM_VERSION}"
else
    check_fail "helm not installed"
fi

# eksctl
if command -v eksctl &> /dev/null; then
    EKSCTL_VERSION=$(eksctl version 2>/dev/null)
    check_pass "eksctl installed: ${EKSCTL_VERSION}"
else
    check_fail "eksctl not installed"
fi

# jq
if command -v jq &> /dev/null; then
    JQ_VERSION=$(jq --version 2>/dev/null)
    check_pass "jq installed: ${JQ_VERSION}"
else
    check_fail "jq not installed"
fi

# curl
if command -v curl &> /dev/null; then
    check_pass "curl installed"
else
    check_fail "curl not installed"
fi

# git (optional but useful)
if command -v git &> /dev/null; then
    check_pass "git installed"
else
    check_warn "git not installed (optional)"
fi

#######################################
# 2. AWS Credentials Check
#######################################
print_header "2. AWS Credentials"

# Check if credentials are configured
if aws sts get-caller-identity &> /dev/null; then
    CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null)
    ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
    USER_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn')
    check_pass "AWS credentials valid"
    check_info "Account: ${ACCOUNT_ID}"
    check_info "Identity: ${USER_ARN}"
else
    check_fail "AWS credentials not configured or invalid"
fi

# Check region
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null)}
if [[ -n "$AWS_REGION" ]]; then
    check_pass "AWS region configured: ${AWS_REGION}"
else
    check_warn "AWS_REGION not set (will need to set in .env)"
fi

#######################################
# 3. Environment Configuration
#######################################
print_header "3. Environment Configuration"

# Check if .env file exists
if [[ -f "${SCRIPT_DIR}/../../.env" ]]; then
    check_pass ".env file exists"

    # Source .env to get variables
    set +e
    source "${SCRIPT_DIR}/../../.env" 2>/dev/null
    set -e

    # Check required variables
    if [[ -n "$CLUSTER_NAME" ]]; then
        check_pass "CLUSTER_NAME set: ${CLUSTER_NAME}"
    else
        check_warn "CLUSTER_NAME not set in .env"
    fi

    if [[ -n "$VPC_ID" ]]; then
        check_pass "VPC_ID set: ${VPC_ID}"
    else
        check_warn "VPC_ID not set in .env"
    fi

    if [[ -n "$PRIVATE_SUBNET_A" ]] && [[ -n "$PRIVATE_SUBNET_B" ]]; then
        if [[ -n "$PRIVATE_SUBNET_D" ]]; then
            check_pass "Private subnets configured (4 AZs)"
        elif [[ -n "$PRIVATE_SUBNET_C" ]]; then
            check_pass "Private subnets configured (3 AZs)"
        else
            check_pass "Private subnets configured (2 AZs)"
        fi
    else
        check_warn "Private subnets not fully configured in .env (minimum 2 required)"
    fi
else
    check_warn ".env file not found (copy from .env.example)"
fi

#######################################
# 4. Network Connectivity Check
#######################################
print_header "4. Network Connectivity"

# Check if we can reach AWS APIs
if curl -s --connect-timeout 5 "https://sts.${AWS_REGION:-us-east-1}.amazonaws.com" > /dev/null 2>&1; then
    check_pass "Can reach AWS STS API"
else
    check_warn "Cannot reach AWS STS API (may need VPC endpoint)"
fi

if curl -s --connect-timeout 5 "https://eks.${AWS_REGION:-us-east-1}.amazonaws.com" > /dev/null 2>&1; then
    check_pass "Can reach AWS EKS API"
else
    check_warn "Cannot reach AWS EKS API (may need VPC endpoint)"
fi

# Check EC2 metadata (indicates running on EC2)
EC2_METADATA_TOKEN=$(curl -s --connect-timeout 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
if [[ -n "$EC2_METADATA_TOKEN" ]]; then
    check_pass "Running on EC2 instance (IMDSv2 available)"

    # Get instance info
    INSTANCE_VPC=$(curl -s -H "X-aws-ec2-metadata-token: $EC2_METADATA_TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -s -H "X-aws-ec2-metadata-token: $EC2_METADATA_TOKEN" http://169.254.169.254/latest/meta-data/mac)/vpc-id 2>/dev/null || true)
    if [[ -n "$INSTANCE_VPC" ]]; then
        check_info "Instance VPC: ${INSTANCE_VPC}"
        if [[ "$INSTANCE_VPC" == "$VPC_ID" ]]; then
            check_pass "Instance is in target VPC"
        elif [[ -n "$VPC_ID" ]]; then
            check_info "Instance VPC differs from target VPC (checking peering connectivity...)"
        fi
    fi

    INSTANCE_SUBNET=$(curl -s -H "X-aws-ec2-metadata-token: $EC2_METADATA_TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -s -H "X-aws-ec2-metadata-token: $EC2_METADATA_TOKEN" http://169.254.169.254/latest/meta-data/mac)/subnet-id 2>/dev/null || true)
    if [[ -n "$INSTANCE_SUBNET" ]]; then
        check_info "Instance Subnet: ${INSTANCE_SUBNET}"
    fi

    # Get instance region for route table queries
    INSTANCE_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $EC2_METADATA_TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)

    # VPC Peering connectivity check (when in different VPC)
    if [[ -n "$VPC_ID" ]] && [[ "$INSTANCE_VPC" != "$VPC_ID" ]]; then
        echo ""
        echo "  Checking VPC Peering connectivity to target VPC..."

        # Check VPC endpoint DNS resolution
        STS_DNS="sts.${AWS_REGION}.amazonaws.com"
        if command -v dig &> /dev/null; then
            STS_IP=$(dig +short "$STS_DNS" 2>/dev/null | head -1)
        elif command -v nslookup &> /dev/null; then
            STS_IP=$(nslookup "$STS_DNS" 2>/dev/null | awk '/^Address: / { print $2 }' | head -1)
        elif command -v getent &> /dev/null; then
            STS_IP=$(getent hosts "$STS_DNS" 2>/dev/null | awk '{ print $1 }' | head -1)
        else
            STS_IP=""
        fi
        if [[ -n "$STS_IP" ]]; then
            # Check if resolved IP is private (10.x, 172.16-31.x, 192.168.x)
            if [[ "$STS_IP" =~ ^10\. ]] || [[ "$STS_IP" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$STS_IP" =~ ^192\.168\. ]]; then
                check_pass "VPC Endpoint DNS resolves to private IP: ${STS_IP}"
            else
                check_info "STS resolves to public IP: ${STS_IP} (VPC endpoints may not exist)"
            fi
        else
            check_warn "Cannot resolve ${STS_DNS}"
        fi

        # Check route table for peering routes to target VPC CIDR
        TARGET_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || true)
        if [[ -n "$TARGET_VPC_CIDR" ]] && [[ "$TARGET_VPC_CIDR" != "None" ]]; then
            check_info "Target VPC CIDR: ${TARGET_VPC_CIDR}"

            # Get route table for current instance's subnet (use instance region, not target region)
            if [[ -n "$INSTANCE_SUBNET" ]] && [[ -n "$INSTANCE_REGION" ]]; then
                ROUTE_TO_TARGET=$(aws ec2 describe-route-tables \
                    --filters "Name=association.subnet-id,Values=${INSTANCE_SUBNET}" \
                    --query "RouteTables[0].Routes[?DestinationCidrBlock=='${TARGET_VPC_CIDR}'].VpcPeeringConnectionId" \
                    --region "$INSTANCE_REGION" \
                    --output text 2>/dev/null || true)

                if [[ -n "$ROUTE_TO_TARGET" ]] && [[ "$ROUTE_TO_TARGET" != "None" ]]; then
                    check_pass "Route to target VPC exists via peering: ${ROUTE_TO_TARGET}"
                else
                    check_warn "No route to target VPC CIDR in route table"
                fi
            fi
        fi

        # Test actual connectivity to target VPC (try VPC endpoint if exists)
        ENDPOINT_COUNT=$(aws ec2 describe-vpc-endpoints \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'length(VpcEndpoints)' \
            --region "$AWS_REGION" \
            --output text 2>/dev/null || echo "0")
        if [[ "$ENDPOINT_COUNT" -gt 0 ]]; then
            check_info "Target VPC has ${ENDPOINT_COUNT} VPC endpoints"
        else
            check_warn "No VPC endpoints found in target VPC (run script 3 first)"
        fi
    fi
else
    check_info "Not running on EC2 (or IMDSv2 not available)"
    check_info "Ensure VPN/Direct Connect access to EKS VPC"
fi

#######################################
# 5. EKS Cluster Access (if exists)
#######################################
print_header "5. EKS Cluster Access"

if [[ -n "$CLUSTER_NAME" ]] && [[ -n "$AWS_REGION" ]]; then
    # Check if cluster exists
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &> /dev/null; then
        check_pass "EKS cluster exists: ${CLUSTER_NAME}"

        # Get cluster endpoint
        CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.endpoint' --output text 2>/dev/null)
        check_info "Endpoint: ${CLUSTER_ENDPOINT}"

        # Check endpoint access configuration
        ENDPOINT_PUBLIC=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text 2>/dev/null)
        ENDPOINT_PRIVATE=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text 2>/dev/null)
        check_info "Public endpoint: ${ENDPOINT_PUBLIC}, Private endpoint: ${ENDPOINT_PRIVATE}"

        if [[ "$ENDPOINT_PRIVATE" == "True" ]] && [[ "$ENDPOINT_PUBLIC" == "False" ]]; then
            check_warn "Cluster is private-only - requires VPC network access"
        fi

        # Try to update kubeconfig
        if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" &> /dev/null; then
            check_pass "kubeconfig updated successfully"

            # Test kubectl access
            if kubectl get nodes --request-timeout=10s &> /dev/null; then
                check_pass "kubectl can access cluster"
                NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
                check_info "Nodes in cluster: ${NODE_COUNT}"
            else
                check_fail "kubectl cannot access cluster (network issue)"
            fi
        else
            check_fail "Failed to update kubeconfig"
        fi
    else
        check_info "EKS cluster '${CLUSTER_NAME}' does not exist yet"
        check_info "This is expected if you haven't run the deployment scripts"
    fi
else
    check_info "CLUSTER_NAME or AWS_REGION not set - skipping cluster access check"
fi

#######################################
# 6. IAM Permissions Check
#######################################
print_header "6. IAM Permissions (Basic Check)"

# Check some basic permissions needed for EKS deployment
echo "  Testing basic IAM permissions..."

# EC2 describe
if aws ec2 describe-vpcs --max-items 1 &> /dev/null; then
    check_pass "ec2:DescribeVpcs"
else
    check_fail "ec2:DescribeVpcs"
fi

# EKS list
if aws eks list-clusters --max-items 1 &> /dev/null; then
    check_pass "eks:ListClusters"
else
    check_fail "eks:ListClusters"
fi

# IAM list roles
if aws iam list-roles --max-items 1 &> /dev/null; then
    check_pass "iam:ListRoles"
else
    check_fail "iam:ListRoles"
fi

# Check if can create IAM roles (important for Pod Identity)
check_info "Full IAM permissions will be validated during deployment"

#######################################
# Summary
#######################################
print_header "Summary"

echo ""
echo -e "  ${GREEN}Passed:${NC}  ${PASS}"
echo -e "  ${RED}Failed:${NC}  ${FAIL}"
echo -e "  ${YELLOW}Warnings:${NC} ${WARN}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ Environment is ready - can operate as bastion replacement${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    exit 0
elif [[ $FAIL -le 2 ]]; then
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ⚠ Minor issues found - review failed checks above${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    exit 1
else
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  ✗ Environment not ready - address failed checks above${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    exit 2
fi
