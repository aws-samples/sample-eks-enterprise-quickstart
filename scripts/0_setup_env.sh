#!/bin/bash

set -e
set -o pipefail
export AWS_PAGER=""

# 日志函数
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
warn() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }

log "Loading environment configuration..."

# 1. 尝试从 .env 文件加载配置（如果存在）
# IMPORTANT: .env entries with empty values (e.g. GPU_INSTANCE_TYPES=)
# must NOT clobber values the caller has already exported. Pre-snapshot
# non-empty env, source the file, then restore snapshotted values so
# explicit `export FOO=bar; bash script.sh` takes precedence over blank
# lines in .env. Discovered 2026-05-04 p6-b300 D-task: .env shipped
# with blank GPU_INSTANCE_TYPES= silently clobbered the exported value
# and created a stray p5 NG.
if [ -f .env ]; then
    log "Loading configuration from .env file (caller exports take precedence)..."
    # Snapshot currently-set (non-empty) env vars that .env might touch
    _env_snapshot_file=$(mktemp /tmp/env_snap.XXXXXX)
    # Extract variable names mentioned in .env (LHS of 'FOO=...' lines)
    _env_keys=$(grep -E '^[A-Z_][A-Z0-9_]*=' .env | cut -d= -f1 | sort -u)
    for _k in $_env_keys; do
        _v="${!_k:-}"
        if [ -n "$_v" ]; then
            printf '%s=%q\n' "$_k" "$_v" >> "$_env_snapshot_file"
        fi
    done
    set -a
    source .env
    set +a
    # Restore snapshotted non-empty values (only if .env blanked them or
    # if .env set them to a value different from the caller's explicit one).
    # Split on first '=' only via parameter expansion — values may legitimately
    # contain '=' (e.g. URLs, base64 strings) and IFS='=' read would truncate.
    if [ -s "$_env_snapshot_file" ]; then
        while IFS= read -r _line; do
            [ -z "${_line}" ] && continue
            _k="${_line%%=*}"
            _v_quoted="${_line#*=}"
            # eval is safe here because _k is a grep-validated identifier
            # and _v_quoted came from printf '%q' (shell-escaped)
            eval "export $_k=$_v_quoted"
        done < "$_env_snapshot_file"
    fi
    rm -f "$_env_snapshot_file"
    unset _env_snapshot_file _env_keys _k _v _v_quoted _line
fi

# 2. 动态获取 AWS Account ID（如果未设置）
if [ -z "$ACCOUNT_ID" ]; then
    log "ACCOUNT_ID not set, fetching from AWS STS..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || \
        error "Failed to get AWS Account ID. Please set ACCOUNT_ID environment variable or configure AWS CLI."
    export ACCOUNT_ID
fi

# 3. 设置 AWS Region（优先级：环境变量 > .env > AWS CLI 配置 > 默认值）
if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
    log "AWS_REGION not set, using: $AWS_REGION"
fi
export AWS_REGION

# 自动设置 AWS_DEFAULT_REGION（如果 .env 中没有设置）
if [ -z "$AWS_DEFAULT_REGION" ]; then
    log "AWS_DEFAULT_REGION not set, auto-setting to: $AWS_REGION"
    export AWS_DEFAULT_REGION="$AWS_REGION"
else
    export AWS_DEFAULT_REGION
fi

# 4. 验证必需的环境变量 (最少需要2个AZ)
REQUIRED_VARS=(
    "CLUSTER_NAME"
    "VPC_ID"
    "PRIVATE_SUBNET_A"
    "PRIVATE_SUBNET_B"
    "PUBLIC_SUBNET_A"
    "PUBLIC_SUBNET_B"
)

# 第3和第4个 AZ 是可选的
# C: 大多数区域有3个AZ
# D: Oregon等区域有4个AZ

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    error "Missing required environment variables: ${MISSING_VARS[*]}. Please create a .env file or set these variables. See .env.example for reference."
fi

# 5. 设置默认值
export K8S_VERSION="${K8S_VERSION:-1.35}"
export SERVICE_IPV4_CIDR="${SERVICE_IPV4_CIDR:-172.20.0.0/16}"

# ============================================
# 组件版本配置（可通过 .env 覆盖）
# ============================================
# Cluster Autoscaler - 版本应与 K8S_VERSION 主版本匹配
export CLUSTER_AUTOSCALER_VERSION="${CLUSTER_AUTOSCALER_VERSION:-v1.35.0}"

# AWS Load Balancer Controller
export ALB_CONTROLLER_VERSION="${ALB_CONTROLLER_VERSION:-v2.14.1}"
export ALB_CONTROLLER_CHART_VERSION="${ALB_CONTROLLER_CHART_VERSION:-1.16.0}"

# Karpenter
export KARPENTER_VERSION="${KARPENTER_VERSION:-1.12.1}"

# CSI Drivers, CoreDNS, and Metrics Server are installed as EKS Managed Addons.
# Versions are automatically selected by AWS based on EKS version compatibility —
# no manual version configuration needed.

# 6. 检测 AZ 数量并自动推导 AZ（支持2-4个AZ）
# 始终设置 A 和 B（必需）
if [ -z "$AZ_A" ]; then export AZ_A="${AWS_REGION}a"; fi
if [ -z "$AZ_B" ]; then export AZ_B="${AWS_REGION}b"; fi

# 检测 AZ 数量
if [ -n "$PRIVATE_SUBNET_D" ] && [ -n "$PUBLIC_SUBNET_D" ]; then
    export AZ_COUNT=4
    if [ -z "$AZ_C" ]; then export AZ_C="${AWS_REGION}c"; fi
    if [ -z "$AZ_D" ]; then export AZ_D="${AWS_REGION}d"; fi
    log "Detected 4 availability zones configuration"
elif [ -n "$PRIVATE_SUBNET_C" ] && [ -n "$PUBLIC_SUBNET_C" ]; then
    export AZ_COUNT=3
    if [ -z "$AZ_C" ]; then export AZ_C="${AWS_REGION}c"; fi
    log "Detected 3 availability zones configuration"
else
    export AZ_COUNT=2
    log "Detected 2 availability zones configuration"
fi

# 7. 验证配置
log "Validating configuration..."

# 验证 AWS 凭证
aws sts get-caller-identity >/dev/null 2>&1 || \
    error "AWS credentials not configured. Please run 'aws configure' or set AWS credentials."

log "Configuration validation completed successfully!"

# 8. 系统节点组配置（高级选项）
# 注意: 默认使用 Graviton4 (ARM64) 实例，脚本会自动选择对应架构的 AMI
export SYSTEM_NODE_INSTANCE_TYPE="${SYSTEM_NODE_INSTANCE_TYPE:-m8g.xlarge}"
export SYSTEM_NODE_ROOT_VOLUME_SIZE="${SYSTEM_NODE_ROOT_VOLUME_SIZE:-50}"
export SYSTEM_NODE_DATA_VOLUME_SIZE="${SYSTEM_NODE_DATA_VOLUME_SIZE:-100}"
export SYSTEM_NODE_DESIRED_CAPACITY="${SYSTEM_NODE_DESIRED_CAPACITY:-3}"
export SYSTEM_NODE_MIN_SIZE="${SYSTEM_NODE_MIN_SIZE:-3}"
export SYSTEM_NODE_MAX_SIZE="${SYSTEM_NODE_MAX_SIZE:-6}"

# 系统节点标签配置（用于调度系统组件）
export SYSTEM_NODE_LABEL_KEY="${SYSTEM_NODE_LABEL_KEY:-app}"
export SYSTEM_NODE_LABEL_VALUE="${SYSTEM_NODE_LABEL_VALUE:-eks-utils}"

# 配置验证
if [[ ! "$SYSTEM_NODE_INSTANCE_TYPE" =~ ^[a-z][0-9]+[a-z]*\.[a-z0-9]+$ ]]; then
    echo "⚠ WARNING: Invalid SYSTEM_NODE_INSTANCE_TYPE format, using default: m8g.xlarge"
    export SYSTEM_NODE_INSTANCE_TYPE="m8g.xlarge"
fi

if [ "$SYSTEM_NODE_DATA_VOLUME_SIZE" -lt 50 ]; then
    echo "⚠ WARNING: SYSTEM_NODE_DATA_VOLUME_SIZE too small, using minimum: 50GB"
    export SYSTEM_NODE_DATA_VOLUME_SIZE=50
fi

# 9. 可选组件配置（默认值）
normalize_bool() {
    local val
    val=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$val" in
        true|1|yes|y) echo "true" ;;
        *) echo "false" ;;
    esac
}

# Storage (gp3/io2 always installed, only IOPS is configurable)
export IO2_IOPS="${IO2_IOPS:-10000}"

# Auto-scaling
export INSTALL_KARPENTER=$(normalize_bool "${INSTALL_KARPENTER:-false}")
export KARPENTER_VERSION="${KARPENTER_VERSION:-1.12.1}"

# File Systems (Optional)
export INSTALL_EFS_CSI=$(normalize_bool "${INSTALL_EFS_CSI:-false}")
export INSTALL_FSX_CSI=$(normalize_bool "${INSTALL_FSX_CSI:-false}")

# 验证 IO2 IOPS 范围
if [ "$IO2_IOPS" -lt 100 ] || [ "$IO2_IOPS" -gt 64000 ]; then
    echo "⚠ WARNING: IO2_IOPS out of range (100-64000), using default: 10000"
    export IO2_IOPS=10000
fi

# 10. 集群访问模式配置
# CLUSTER_MODE: private（默认）或 public
CLUSTER_MODE="${CLUSTER_MODE:-private}"
CLUSTER_MODE=$(echo "$CLUSTER_MODE" | tr '[:upper:]' '[:lower:]')

if [ "${CLUSTER_MODE}" != "private" ] && [ "${CLUSTER_MODE}" != "public" ]; then
    error "Invalid CLUSTER_MODE '${CLUSTER_MODE}'. Must be 'private' or 'public'."
fi
export CLUSTER_MODE

# VPC_ENDPOINTS_MODE: full（默认 private 模式）或 minimal（默认 public 模式）
if [ -z "${VPC_ENDPOINTS_MODE:-}" ]; then
    if [ "${CLUSTER_MODE}" = "public" ]; then
        VPC_ENDPOINTS_MODE="minimal"
    else
        VPC_ENDPOINTS_MODE="full"
    fi
fi
VPC_ENDPOINTS_MODE=$(echo "$VPC_ENDPOINTS_MODE" | tr '[:upper:]' '[:lower:]')

if [ "${VPC_ENDPOINTS_MODE}" != "full" ] && [ "${VPC_ENDPOINTS_MODE}" != "minimal" ]; then
    error "Invalid VPC_ENDPOINTS_MODE '${VPC_ENDPOINTS_MODE}'. Must be 'full' or 'minimal'."
fi
export VPC_ENDPOINTS_MODE

# Public 访问 CIDR（仅 public 模式有效）
export PUBLIC_ACCESS_CIDRS="${PUBLIC_ACCESS_CIDRS:-0.0.0.0/0}"

# 11. 构建子网列表变量（供其他脚本使用，支持2-4个AZ）
case "$AZ_COUNT" in
    4)
        export PRIVATE_SUBNETS="${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B},${PRIVATE_SUBNET_C},${PRIVATE_SUBNET_D}"
        export PUBLIC_SUBNETS="${PUBLIC_SUBNET_A},${PUBLIC_SUBNET_B},${PUBLIC_SUBNET_C},${PUBLIC_SUBNET_D}"
        ;;
    3)
        export PRIVATE_SUBNETS="${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B},${PRIVATE_SUBNET_C}"
        export PUBLIC_SUBNETS="${PUBLIC_SUBNET_A},${PUBLIC_SUBNET_B},${PUBLIC_SUBNET_C}"
        ;;
    2)
        export PRIVATE_SUBNETS="${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B}"
        export PUBLIC_SUBNETS="${PUBLIC_SUBNET_A},${PUBLIC_SUBNET_B}"
        ;;
esac

# 12. 显示配置摘要
log "=== Configuration Summary ==="
echo "ACCOUNT_ID: $ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "K8S_VERSION: $K8S_VERSION"
echo "VPC_ID: $VPC_ID"

case "$AZ_COUNT" in
    4)
        echo "AZ: $AZ_A, $AZ_B, $AZ_C, $AZ_D (4 Availability Zones)"
        echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B, $PRIVATE_SUBNET_C, $PRIVATE_SUBNET_D"
        echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B, $PUBLIC_SUBNET_C, $PUBLIC_SUBNET_D"
        ;;
    3)
        echo "AZ: $AZ_A, $AZ_B, $AZ_C (3 Availability Zones)"
        echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B, $PRIVATE_SUBNET_C"
        echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B, $PUBLIC_SUBNET_C"
        ;;
    2)
        echo "AZ: $AZ_A, $AZ_B (2 Availability Zones)"
        echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B"
        echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B"
        ;;
esac
echo "SYSTEM_NODE_INSTANCE_TYPE: $SYSTEM_NODE_INSTANCE_TYPE"
echo "SYSTEM_NODE_DATA_VOLUME_SIZE: ${SYSTEM_NODE_DATA_VOLUME_SIZE}GB"
echo "SYSTEM_NODE_LABEL: ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}"
echo ""
if [ "${CLUSTER_MODE}" = "public" ]; then
    echo "Cluster Access Mode: PUBLIC (API Server 公网+VPC 双通道)"
    echo "  Public Access CIDRs: ${PUBLIC_ACCESS_CIDRS}"
    if [ "${PUBLIC_ACCESS_CIDRS}" = "0.0.0.0/0" ]; then
        warn "PUBLIC_ACCESS_CIDRS is 0.0.0.0/0 — consider restricting to known IP ranges for security"
    fi
else
    echo "Cluster Access Mode: PRIVATE (API Server 仅 VPC 内可访问)"
fi
echo "VPC Endpoints Mode: ${VPC_ENDPOINTS_MODE}"
echo ""
echo "Optional Components:"
echo "  - Karpenter: $INSTALL_KARPENTER $([ "$INSTALL_KARPENTER" = "true" ] && echo "(v${KARPENTER_VERSION})" || echo "")"
echo "  - EBS CSI: Install via ./scripts/legacy/option_install_csi_drivers.sh ebs (gp3/io2 StorageClass)"
echo "  - EFS CSI: $INSTALL_EFS_CSI"
echo "  - FSx CSI: $INSTALL_FSX_CSI"
log "============================"

# ============================================================
# Kubectl Context Verification Function
# ============================================================
# 验证 kubectl 是否连接到正确的集群
# 用法: verify_kubectl_context
verify_kubectl_context() {
    local cluster_name="${CLUSTER_NAME}"
    local region="${AWS_REGION}"

    if [ -z "${cluster_name}" ]; then
        error "CLUSTER_NAME not set, cannot verify kubectl context"
    fi

    log "Verifying kubectl is connected to cluster '${cluster_name}'..."

    # 首先更新 kubeconfig 确保连接到正确的集群
    if ! aws eks update-kubeconfig --name "${cluster_name}" --region "${region}" &>/dev/null; then
        error "Failed to update kubeconfig for cluster '${cluster_name}'"
    fi

    # 检查当前 context 是否包含集群名
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "")

    if [[ "${current_context}" != *"${cluster_name}"* ]]; then
        log "WARNING: kubectl context '${current_context}' doesn't match cluster '${cluster_name}'"
        log "Forcing context update with alias..."
        aws eks update-kubeconfig --region "${region}" --name "${cluster_name}" --alias "${cluster_name}"
        current_context=$(kubectl config current-context 2>/dev/null || echo "")
    fi

    # 验证 API endpoint 匹配
    local expected_endpoint
    local current_endpoint

    expected_endpoint=$(aws eks describe-cluster --name "${cluster_name}" --region "${region}" --query 'cluster.endpoint' --output text 2>/dev/null)
    current_endpoint=$(kubectl config view --minify --output jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")

    if [ -z "${expected_endpoint}" ]; then
        error "Failed to get cluster endpoint for '${cluster_name}'"
    fi

    if [ "${current_endpoint}" != "${expected_endpoint}" ]; then
        error "kubectl is pointing to WRONG cluster endpoint!
  Expected: ${expected_endpoint}
  Current:  ${current_endpoint}
  Kubeconfig: ${KUBECONFIG:-default}

Please ensure you are operating on the correct cluster."
    fi

    log "✓ kubectl verified - connected to cluster '${cluster_name}'"
    log "  Context: ${current_context}"
    log "  Endpoint: ${current_endpoint}"
}

# ============================================
# Resource Validation Functions
# ============================================

# Validate VPC exists
validate_vpc_exists() {
    local vpc_id="${1}"
    local region="${2:-${AWS_REGION}}"

    if [ -z "${vpc_id}" ]; then
        error "VPC ID is required"
    fi

    log "Validating VPC ${vpc_id}..."
    if ! aws ec2 describe-vpcs \
        --vpc-ids "${vpc_id}" \
        --region "${region}" \
        --query 'Vpcs[0].VpcId' \
        --output text &>/dev/null; then
        error "VPC '${vpc_id}' not found in region '${region}'"
    fi
    log "✓ VPC ${vpc_id} validated"
}

# Validate subnet exists and belongs to VPC
validate_subnet_exists() {
    local subnet_id="${1}"
    local expected_vpc_id="${2:-}"
    local region="${3:-${AWS_REGION}}"

    if [ -z "${subnet_id}" ]; then
        error "Subnet ID is required"
    fi

    log "Validating subnet ${subnet_id}..."
    local subnet_info
    subnet_info=$(aws ec2 describe-subnets \
        --subnet-ids "${subnet_id}" \
        --region "${region}" \
        --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone]' \
        --output text 2>/dev/null)

    if [ -z "${subnet_info}" ]; then
        error "Subnet '${subnet_id}' not found in region '${region}'"
    fi

    local actual_vpc_id=$(echo "${subnet_info}" | awk '{print $2}')
    local az=$(echo "${subnet_info}" | awk '{print $3}')

    if [ -n "${expected_vpc_id}" ] && [ "${actual_vpc_id}" != "${expected_vpc_id}" ]; then
        error "Subnet '${subnet_id}' belongs to VPC '${actual_vpc_id}', expected '${expected_vpc_id}'"
    fi

    log "✓ Subnet ${subnet_id} validated (VPC: ${actual_vpc_id}, AZ: ${az})"
}

# Validate multiple subnets
validate_subnets() {
    local subnet_list="${1}"
    local vpc_id="${2:-}"
    local region="${3:-${AWS_REGION}}"

    if [ -z "${subnet_list}" ]; then
        error "Subnet list is required"
    fi

    IFS=',' read -ra SUBNETS <<< "${subnet_list}"
    for subnet_id in "${SUBNETS[@]}"; do
        subnet_id=$(echo "${subnet_id}" | xargs)  # Trim whitespace
        validate_subnet_exists "${subnet_id}" "${vpc_id}" "${region}"
    done
}

# Validate AMI exists
validate_ami_exists() {
    local ami_id="${1}"
    local region="${2:-${AWS_REGION}}"

    if [ -z "${ami_id}" ]; then
        error "AMI ID is required"
    fi

    log "Validating AMI ${ami_id}..."
    local ami_info
    ami_info=$(aws ec2 describe-images \
        --image-ids "${ami_id}" \
        --region "${region}" \
        --query 'Images[0].[ImageId,State,Name]' \
        --output text 2>/dev/null)

    if [ -z "${ami_info}" ]; then
        error "AMI '${ami_id}' not found in region '${region}'"
    fi

    local ami_state=$(echo "${ami_info}" | awk '{print $2}')
    local ami_name=$(echo "${ami_info}" | awk '{$1=$2=""; print $0}' | xargs)

    if [ "${ami_state}" != "available" ]; then
        error "AMI '${ami_id}' is not available (state: ${ami_state})"
    fi

    log "✓ AMI ${ami_id} validated (${ami_name})"
}

# Validate security group exists
validate_security_group_exists() {
    local sg_id="${1}"
    local expected_vpc_id="${2:-}"
    local region="${3:-${AWS_REGION}}"

    if [ -z "${sg_id}" ]; then
        error "Security Group ID is required"
    fi

    log "Validating security group ${sg_id}..."
    local sg_info
    sg_info=$(aws ec2 describe-security-groups \
        --group-ids "${sg_id}" \
        --region "${region}" \
        --query 'SecurityGroups[0].[GroupId,VpcId,GroupName]' \
        --output text 2>/dev/null)

    if [ -z "${sg_info}" ]; then
        error "Security Group '${sg_id}' not found in region '${region}'"
    fi

    local actual_vpc_id=$(echo "${sg_info}" | awk '{print $2}')
    local sg_name=$(echo "${sg_info}" | awk '{print $3}')

    if [ -n "${expected_vpc_id}" ] && [ "${actual_vpc_id}" != "${expected_vpc_id}" ]; then
        error "Security Group '${sg_id}' belongs to VPC '${actual_vpc_id}', expected '${expected_vpc_id}'"
    fi

    log "✓ Security Group ${sg_id} validated (${sg_name}, VPC: ${actual_vpc_id})"
}

# Validate IAM role exists
validate_iam_role_exists() {
    local role_name="${1}"

    if [ -z "${role_name}" ]; then
        error "IAM role name is required"
    fi

    log "Validating IAM role ${role_name}..."
    if ! aws iam get-role \
        --role-name "${role_name}" \
        --query 'Role.RoleName' \
        --output text &>/dev/null; then
        error "IAM role '${role_name}' not found"
    fi

    log "✓ IAM role ${role_name} validated"
}

# Validate IAM instance profile exists
validate_instance_profile_exists() {
    local profile_name="${1}"

    if [ -z "${profile_name}" ]; then
        error "Instance profile name is required"
    fi

    log "Validating instance profile ${profile_name}..."
    if ! aws iam get-instance-profile \
        --instance-profile-name "${profile_name}" \
        --query 'InstanceProfile.InstanceProfileName' \
        --output text &>/dev/null; then
        error "Instance profile '${profile_name}' not found"
    fi

    log "✓ Instance profile ${profile_name} validated"
}

# Validate EKS cluster exists
validate_eks_cluster_exists() {
    local cluster_name="${1}"
    local region="${2:-${AWS_REGION}}"

    if [ -z "${cluster_name}" ]; then
        error "Cluster name is required"
    fi

    log "Validating EKS cluster ${cluster_name}..."
    local cluster_status
    cluster_status=$(aws eks describe-cluster \
        --name "${cluster_name}" \
        --region "${region}" \
        --query 'cluster.status' \
        --output text 2>/dev/null)

    if [ -z "${cluster_status}" ]; then
        error "EKS cluster '${cluster_name}' not found in region '${region}'"
    fi

    if [ "${cluster_status}" != "ACTIVE" ]; then
        warn "EKS cluster '${cluster_name}' is not ACTIVE (status: ${cluster_status})"
    fi

    log "✓ EKS cluster ${cluster_name} validated (status: ${cluster_status})"
}
