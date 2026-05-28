#!/bin/bash

set -e
set -o pipefail
export AWS_PAGER=""

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "=== EKS Cluster Installation with Cluster Autoscaler and EBS CSI Driver ==="

# 1. Load environment variables
source "${SCRIPT_DIR}/../0_setup_env.sh"

# 1.1 Set KUBECONFIG environment variable
export KUBECONFIG="${HOME:-/root}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.5. Import Pod Identity helper functions
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 1.6. Check required dependencies
echo "Checking required dependencies..."
MISSING_DEPS=()

command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v eksctl >/dev/null 2>&1 || MISSING_DEPS+=("eksctl")
command -v helm >/dev/null 2>&1 || MISSING_DEPS+=("helm")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v aws >/dev/null 2>&1 || MISSING_DEPS+=("aws cli")

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "❌ ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    echo ""
    echo "Please install the missing dependencies and try again."
    exit 1
fi
echo "✓ All required dependencies are installed"
echo ""


# ===================================================================
# Main workflow
# ===================================================================

# Validate VPC and subnets before cluster creation
echo "Validating AWS resources..."
validate_vpc_exists "${VPC_ID}" "${AWS_REGION}"
validate_subnets "${PRIVATE_SUBNETS}" "${VPC_ID}" "${AWS_REGION}"
echo ""

# 2. Create EKS cluster (control plane)
echo "Step 2: Creating EKS cluster control plane..."

# Check if cluster already exists
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "⚠️  Cluster '${CLUSTER_NAME}' already exists"
    echo "Skipping cluster creation..."
else
    echo "Creating new cluster..."

    # Determine cluster endpoint access mode
    if [ "${CLUSTER_MODE:-private}" = "public" ]; then
        CLUSTER_PUBLIC_ACCESS="true"
        echo "⚠️  CLUSTER_MODE=public: API Server will be accessible from the internet"
        echo "   Public Access CIDRs: ${PUBLIC_ACCESS_CIDRS:-0.0.0.0/0}"
        if [ "${PUBLIC_ACCESS_CIDRS:-0.0.0.0/0}" = "0.0.0.0/0" ]; then
            echo "   ⚠️  WARNING: PUBLIC_ACCESS_CIDRS is 0.0.0.0/0 — consider restricting to known IPs"
        fi
        # Build publicAccessCIDRs YAML block
        PUBLIC_ACCESS_CIDRS_YAML="  publicAccessCIDRs:"
        IFS=',' read -ra CIDR_LIST <<< "${PUBLIC_ACCESS_CIDRS:-0.0.0.0/0}"
        for cidr in "${CIDR_LIST[@]}"; do
            cidr=$(echo "${cidr}" | xargs)
            PUBLIC_ACCESS_CIDRS_YAML="${PUBLIC_ACCESS_CIDRS_YAML}
    - \"${cidr}\""
        done
    else
        CLUSTER_PUBLIC_ACCESS="false"
        PUBLIC_ACCESS_CIDRS_YAML=""
        echo "✓ CLUSTER_MODE=private: API Server accessible from VPC only"
    fi

    # Prepare secretsEncryption configuration if KMS_KEY_ARN is set
    if [ -n "${KMS_KEY_ARN:-}" ]; then
        echo "✓ KMS encryption enabled: ${KMS_KEY_ARN}"
        SECRETS_ENCRYPTION_CONFIG="secretsEncryption:
  keyARN: ${KMS_KEY_ARN}"
    else
        echo "⚠️  KMS encryption not configured (KMS_KEY_ARN not set)"
        SECRETS_ENCRYPTION_CONFIG=""
    fi

    # Build dynamic subnet configuration based on AZ_COUNT (supports 2-4 AZs)
    PRIVATE_SUBNETS_YAML="      ${AZ_A}:
        id: \"${PRIVATE_SUBNET_A}\"
      ${AZ_B}:
        id: \"${PRIVATE_SUBNET_B}\""
    PUBLIC_SUBNETS_YAML="      ${AZ_A}:
        id: \"${PUBLIC_SUBNET_A}\"
      ${AZ_B}:
        id: \"${PUBLIC_SUBNET_B}\""

    if [ "${AZ_COUNT}" -ge 3 ] && [ -n "${PRIVATE_SUBNET_C}" ]; then
        PRIVATE_SUBNETS_YAML="${PRIVATE_SUBNETS_YAML}
      ${AZ_C}:
        id: \"${PRIVATE_SUBNET_C}\""
        PUBLIC_SUBNETS_YAML="${PUBLIC_SUBNETS_YAML}
      ${AZ_C}:
        id: \"${PUBLIC_SUBNET_C}\""
    fi
    if [ "${AZ_COUNT}" -ge 4 ] && [ -n "${PRIVATE_SUBNET_D}" ]; then
        PRIVATE_SUBNETS_YAML="${PRIVATE_SUBNETS_YAML}
      ${AZ_D}:
        id: \"${PRIVATE_SUBNET_D}\""
        PUBLIC_SUBNETS_YAML="${PUBLIC_SUBNETS_YAML}
      ${AZ_D}:
        id: \"${PUBLIC_SUBNET_D}\""
    fi

    # Generate cluster config dynamically
    cat > "${PROJECT_ROOT}/eksctl_cluster_final.yaml" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
  tags:
    cluster-autoscaler: enabled

autoModeConfig:
  enabled: false

${SECRETS_ENCRYPTION_CONFIG}

kubernetesNetworkConfig:
  serviceIPv4CIDR: "${SERVICE_IPV4_CIDR}"

vpc:
  id: "${VPC_ID}"
  subnets:
    private:
${PRIVATE_SUBNETS_YAML}
    public:
${PUBLIC_SUBNETS_YAML}
  clusterEndpoints:
    privateAccess: true
    publicAccess: ${CLUSTER_PUBLIC_ACCESS}
${PUBLIC_ACCESS_CIDRS_YAML}

accessConfig:
  authenticationMode: API_AND_CONFIG_MAP

iam:
  withOIDC: false

managedNodeGroups: []

addons:
  - name: vpc-cni
    version: latest
    configurationValues: |
      env:
        AWS_VPC_K8S_CNI_EXTERNALSNAT: "false"
        WARM_ENI_TARGET: "0"
        WARM_IP_TARGET: "5"
        MINIMUM_IP_TARGET: "3"
  - name: kube-proxy
    version: latest
  - name: eks-pod-identity-agent
    version: latest
  - name: coredns
    version: latest
    configurationValues: |
      replicaCount: 2
      nodeSelector:
        ${SYSTEM_NODE_LABEL_KEY}: ${SYSTEM_NODE_LABEL_VALUE}
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  k8s-app: kube-dns
              topologyKey: kubernetes.io/hostname
  - name: metrics-server
    version: latest
    configurationValues: |
      replicas: 2
      nodeSelector:
        ${SYSTEM_NODE_LABEL_KEY}: ${SYSTEM_NODE_LABEL_VALUE}
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  k8s-app: metrics-server
              topologyKey: kubernetes.io/hostname

cloudWatch:
  clusterLogging:
    logRetentionInDays: 30
    enableTypes:
      - "api"
      - "audit"
      - "authenticator"
      - "controllerManager"
      - "scheduler"
EOF

    echo "Generated cluster config with ${AZ_COUNT} AZs"
    eksctl create cluster -f "${PROJECT_ROOT}/eksctl_cluster_final.yaml"
fi

# 3. Wait for cluster control plane to be ready
echo ""
echo "Step 3: Waiting for cluster control plane to be ready..."
aws eks wait cluster-active --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
echo "✓ Cluster control plane is ready"

# 4. Enable deletion protection
if [ "${ENABLE_DELETION_PROTECTION:-true}" = "true" ]; then
    echo ""
    echo "Step 4: Enabling deletion protection..."
    if aws eks update-cluster-config \
            --name "${CLUSTER_NAME}" \
            --region "${AWS_REGION}" \
            --deletion-protection \
            --output text --query 'update.id' >/dev/null 2>&1; then
        echo "✓ Deletion protection enabled"
    else
        echo "⚠️  Failed to enable deletion protection (continuing)"
    fi
fi

# 5. Complete
echo ""
echo "=== EKS Cluster Control Plane Created Successfully ==="
echo ""
echo "Cluster Information:"
echo "  Name: ${CLUSTER_NAME}"
echo "  Region: ${AWS_REGION}"
echo "  Version: ${K8S_VERSION}"
echo "  VPC ID: ${VPC_ID}"
echo ""
echo "Security Configuration:"
if [ -n "${KMS_KEY_ARN:-}" ]; then
    echo "  Secrets Encryption: ✓ Enabled (KMS)"
else
    echo "  Secrets Encryption: ✗ Disabled (set KMS_KEY_ARN to enable)"
fi
if [ "${ENABLE_DELETION_PROTECTION:-true}" = "true" ]; then
    echo "  Deletion Protection: ✓ Enabled"
else
    echo "  Deletion Protection: ✗ Disabled"
fi
if [ "${CLUSTER_MODE:-private}" = "public" ]; then
    echo "  API Endpoint Access: PUBLIC (privateAccess=true, publicAccess=true)"
    echo "  Public Access CIDRs: ${PUBLIC_ACCESS_CIDRS:-0.0.0.0/0}"
else
    echo "  API Endpoint Access: PRIVATE (privateAccess=true, publicAccess=false)"
fi
echo ""
echo "⚠️  IMPORTANT: System nodegroup NOT created yet"
echo ""
echo "Next steps:"
echo "  1. Create system nodegroup with LVM (REQUIRED):"
echo "     ./scripts/legacy/6_create_system_nodegroup.sh"
echo ""
echo "  2. After nodegroup is ready, install addons:"
echo "     ./scripts/legacy/7_install_eks_addon.sh"
echo ""
