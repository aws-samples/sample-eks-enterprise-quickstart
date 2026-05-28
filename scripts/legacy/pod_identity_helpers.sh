#!/bin/bash

# Pod Identity Helper Functions
# 提供可重用的 Pod Identity 设置函数，用于所有 EKS add-ons

set -e
set -o pipefail
export AWS_PAGER=""

# ============================================
# 日志函数
# ============================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
    exit 1
}

warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

# ============================================
# 核心 Pod Identity 函数
# ============================================

# 创建 IAM 角色（使用 Pod Identity trust policy）
# 参数: $1 = role_name
create_pod_identity_role() {
    local role_name="$1"

    if [ -z "$role_name" ]; then
        error "Role name is required"
    fi

    log "Creating IAM role: ${role_name}"

    # 检查角色是否已存在
    if aws iam get-role --role-name "${role_name}" &>/dev/null; then
        log "Role ${role_name} already exists, skipping creation"
        return 0
    fi

    # 创建 trust policy 文档
    local trust_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF
)

    # 创建角色
    if aws iam create-role \
        --role-name "${role_name}" \
        --assume-role-policy-document "${trust_policy}" \
        --description "Pod Identity role for ${role_name}" \
        --tags Key=ManagedBy,Value=pod-identity-helpers Key=Cluster,Value=${CLUSTER_NAME} &>/dev/null; then
        log "✓ Role ${role_name} created successfully"
    else
        error "Failed to create role ${role_name}"
    fi
}

# 附加 AWS 托管策略到角色
# 参数: $1 = role_name, $2 = policy_arn
attach_managed_policy() {
    local role_name="$1"
    local policy_arn="$2"

    if [ -z "$role_name" ] || [ -z "$policy_arn" ]; then
        error "Role name and policy ARN are required"
    fi

    log "Attaching policy ${policy_arn} to role ${role_name}"

    # 检查策略是否已附加
    if aws iam list-attached-role-policies --role-name "${role_name}" \
        --query "AttachedPolicies[?PolicyArn=='${policy_arn}'].PolicyArn" \
        --output text | grep -q "${policy_arn}"; then
        log "Policy already attached, skipping"
        return 0
    fi

    # 附加策略
    if aws iam attach-role-policy \
        --role-name "${role_name}" \
        --policy-arn "${policy_arn}" &>/dev/null; then
        log "✓ Policy attached successfully"
    else
        error "Failed to attach policy to role ${role_name}"
    fi
}

# 附加自定义策略到角色
# 参数: $1 = role_name, $2 = policy_name, $3 = policy_document_file
attach_custom_policy() {
    local role_name="$1"
    local policy_name="$2"
    local policy_document="$3"

    if [ -z "$role_name" ] || [ -z "$policy_name" ] || [ -z "$policy_document" ]; then
        error "Role name, policy name, and policy document are required"
    fi

    log "Creating and attaching custom policy ${policy_name}"

    # 检查策略是否已存在
    local policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}"

    if ! aws iam get-policy --policy-arn "${policy_arn}" &>/dev/null; then
        # 创建策略
        log "Creating policy ${policy_name}"
        if aws iam create-policy \
            --policy-name "${policy_name}" \
            --policy-document "${policy_document}" &>/dev/null; then
            log "✓ Policy ${policy_name} created"
        else
            error "Failed to create policy ${policy_name}"
        fi
    else
        log "Policy ${policy_name} already exists, updating to latest version..."
        # 删除非默认的旧版本（AWS 限制最多 5 个版本）
        local old_versions
        old_versions=$(aws iam list-policy-versions --policy-arn "${policy_arn}" \
            --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null)
        for version in $old_versions; do
            aws iam delete-policy-version --policy-arn "${policy_arn}" --version-id "${version}" 2>/dev/null || true
        done
        # 创建新版本并设为默认
        if aws iam create-policy-version \
            --policy-arn "${policy_arn}" \
            --policy-document "${policy_document}" \
            --set-as-default &>/dev/null; then
            log "✓ Policy ${policy_name} updated"
        else
            warn "Failed to update policy ${policy_name}, continuing with existing version"
        fi
    fi

    # 附加策略
    attach_managed_policy "${role_name}" "${policy_arn}"
}

# 创建 Pod Identity Association
# 参数: $1 = namespace, $2 = service_account, $3 = role_name
create_pod_identity_association() {
    local namespace="$1"
    local service_account="$2"
    local role_name="$3"

    if [ -z "$namespace" ] || [ -z "$service_account" ] || [ -z "$role_name" ]; then
        error "Namespace, service account, and role name are required"
    fi

    local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"

    log "Creating Pod Identity Association for ${namespace}/${service_account}"

    # 检查 association 是否已存在
    local existing_association=$(aws eks list-pod-identity-associations \
        --cluster-name "${CLUSTER_NAME}" \
        --namespace "${namespace}" \
        --service-account "${service_account}" \
        --query 'associations[0].associationId' \
        --output text 2>/dev/null)

    if [ -n "$existing_association" ] && [ "$existing_association" != "None" ]; then
        log "Pod Identity Association already exists (ID: ${existing_association}), skipping"
        return 0
    fi

    # 创建 association
    if aws eks create-pod-identity-association \
        --cluster-name "${CLUSTER_NAME}" \
        --namespace "${namespace}" \
        --service-account "${service_account}" \
        --role-arn "${role_arn}" &>/dev/null; then
        log "✓ Pod Identity Association created successfully"
    else
        error "Failed to create Pod Identity Association for ${namespace}/${service_account}"
    fi
}

# 等待 Pod Identity Agent 就绪
wait_for_pod_identity_agent() {
    log "Waiting for Pod Identity Agent to be ready..."

    local max_wait=300
    local elapsed=0
    local interval=10

    while [ $elapsed -lt $max_wait ]; do
        # 检查 DaemonSet 是否存在
        if kubectl get daemonset eks-pod-identity-agent -n kube-system &>/dev/null; then
            # 检查是否所有 pods 都 ready
            local desired=$(kubectl get daemonset eks-pod-identity-agent -n kube-system -o jsonpath='{.status.desiredNumberScheduled}')
            local ready=$(kubectl get daemonset eks-pod-identity-agent -n kube-system -o jsonpath='{.status.numberReady}')

            if [ "$desired" -eq "$ready" ] && [ "$ready" -gt 0 ]; then
                log "✓ Pod Identity Agent is ready (${ready}/${desired} pods)"
                return 0
            else
                log "Waiting... (${ready}/${desired} pods ready)"
            fi
        else
            log "Waiting for Pod Identity Agent DaemonSet to be created..."
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    error "Timeout waiting for Pod Identity Agent to be ready"
}

# 创建 Kubernetes ServiceAccount（如果不存在）
# 参数: $1 = namespace, $2 = service_account
create_service_account() {
    local namespace="$1"
    local service_account="$2"

    if [ -z "$namespace" ] || [ -z "$service_account" ]; then
        error "Namespace and service account name are required"
    fi

    log "Ensuring ServiceAccount ${namespace}/${service_account} exists"

    # 检查 ServiceAccount 是否已存在
    if kubectl get serviceaccount "${service_account}" -n "${namespace}" &>/dev/null; then
        log "ServiceAccount already exists, skipping creation"
        return 0
    fi

    # 创建 ServiceAccount
    if kubectl create serviceaccount "${service_account}" -n "${namespace}" &>/dev/null; then
        log "✓ ServiceAccount created successfully"
    else
        warn "Failed to create ServiceAccount (may already exist or will be created by deployment)"
    fi
}

# ============================================
# 组件特定设置函数
# ============================================

# 设置 Cluster Autoscaler Pod Identity
setup_cluster_autoscaler_pod_identity() {
    log "=========================================="
    log "Setting up Cluster Autoscaler with Pod Identity"
    log "=========================================="

    local role_name="${CLUSTER_NAME}-cluster-autoscaler-role"
    local namespace="kube-system"
    local service_account="cluster-autoscaler"

    # 1. 创建 IAM 角色
    create_pod_identity_role "${role_name}"

    # 2. 附加 AWS 托管策略
    local policy_arn="arn:aws:iam::aws:policy/AmazonEKSClusterAutoscalerPolicy"

    # 检查策略是否存在（某些 partition 可能没有这个策略）
    if ! aws iam get-policy --policy-arn "${policy_arn}" &>/dev/null; then
        log "AmazonEKSClusterAutoscalerPolicy not found, creating custom policy"

        # 创建自定义 Autoscaler 策略
        local policy_doc=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": ["*"]
    }
  ]
}
EOF
)
        attach_custom_policy "${role_name}" "${CLUSTER_NAME}-ClusterAutoscalerPolicy" "${policy_doc}"
    else
        attach_managed_policy "${role_name}" "${policy_arn}"
    fi

    # 3. 创建 ServiceAccount（如果不存在）
    create_service_account "${namespace}" "${service_account}"

    # 4. 创建 Pod Identity Association
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ Cluster Autoscaler Pod Identity setup complete"
}

# 设置 EBS CSI Driver Pod Identity
setup_ebs_csi_pod_identity() {
    log "=========================================="
    log "Setting up EBS CSI Driver with Pod Identity"
    log "=========================================="

    local role_name="${CLUSTER_NAME}-ebs-csi-driver-role"
    local namespace="kube-system"
    local service_account="ebs-csi-controller-sa"

    # 1. 创建 IAM 角色
    create_pod_identity_role "${role_name}"

    # 2. 附加 AWS 托管策略
    local policy_arn="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    attach_managed_policy "${role_name}" "${policy_arn}"

    # 3. ServiceAccount 由 EBS CSI addon 自动创建，无需手动创建

    # 4. 创建 Pod Identity Association
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ EBS CSI Driver Pod Identity setup complete"
}

# 设置 AWS Load Balancer Controller Pod Identity
setup_alb_controller_pod_identity() {
    log "=========================================="
    log "Setting up AWS Load Balancer Controller with Pod Identity"
    log "=========================================="

    local role_name="AWSLoadBalancerControllerRole-${CLUSTER_NAME}"
    local policy_name="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
    local namespace="kube-system"
    local service_account="aws-load-balancer-controller"

    # 1. 下载 IAM policy（如果不存在）
    local policy_file="${PROJECT_ROOT}/terraform/assets/iam/alb-controller-iam-policy.json"
    if [ ! -f "${policy_file}" ]; then
        log "Downloading AWS Load Balancer Controller IAM policy (${ALB_CONTROLLER_VERSION})..."
        mkdir -p "$(dirname "${policy_file}")"
        curl -sS -o "${policy_file}" "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${ALB_CONTROLLER_VERSION}/docs/install/iam_policy.json"
        log "✓ Policy downloaded to ${policy_file}"
    else
        log "Policy file already exists, using existing file"
    fi

    # 2. 创建 IAM 角色
    create_pod_identity_role "${role_name}"

    # 3. 创建和附加自定义策略
    attach_custom_policy "${role_name}" "${policy_name}" "file://${policy_file}"

    # 4. 创建 ServiceAccount（Helm chart 会创建，但我们先创建以确保存在）
    create_service_account "${namespace}" "${service_account}"

    # 5. 创建 Pod Identity Association
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ AWS Load Balancer Controller Pod Identity setup complete"
}

# 设置 EFS CSI Driver Pod Identity
setup_efs_csi_pod_identity() {
    log "=========================================="
    log "Setting up EFS CSI Driver with Pod Identity"
    log "=========================================="

    local role_name="${CLUSTER_NAME}-efs-csi-driver-role"
    local namespace="kube-system"
    local service_account="efs-csi-controller-sa"

    # 1. 创建 IAM 角色
    create_pod_identity_role "${role_name}"

    # 2. 附加 AWS 托管策略
    local policy_arn="arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
    attach_managed_policy "${role_name}" "${policy_arn}"

    # 3. 创建 ServiceAccount
    create_service_account "${namespace}" "${service_account}"

    # 4. 创建 Pod Identity Association
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ EFS CSI Driver Pod Identity setup complete"
}

# 设置 FSx CSI Driver Pod Identity
setup_fsx_csi_pod_identity() {
    log "=========================================="
    log "Setting up FSx CSI Driver with Pod Identity"
    log "=========================================="

    local role_name="${CLUSTER_NAME}-fsx-csi-driver-role"
    local policy_name="${CLUSTER_NAME}-FSxCSIDriverPolicy"
    local namespace="kube-system"
    local service_account="fsx-csi-controller-sa"

    # 1. 创建 IAM 角色
    create_pod_identity_role "${role_name}"

    # 2. 创建和附加自定义策略
    local policy_file="${PROJECT_ROOT}/terraform/assets/iam/fsx-csi-policy.json"
    if [ ! -f "${policy_file}" ]; then
        error "FSx CSI policy file not found: ${policy_file}"
    fi
    attach_custom_policy "${role_name}" "${policy_name}" "file://${policy_file}"

    # 3. 创建 ServiceAccount
    create_service_account "${namespace}" "${service_account}"

    # 4. 创建 Pod Identity Association
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ FSx CSI Driver Pod Identity setup complete"
}

# 设置 S3 CSI Driver Pod Identity
# 参数: $1 = bucket_arns (逗号分隔的 S3 bucket ARNs)
# 注意:
#   - 需要 Mountpoint for Amazon S3 CSI Driver v2.x+
#   - 支持 S3 Express One Zone (directory buckets)
#   - Directory bucket format: bucket-name--zone-id--x-s3
setup_s3_csi_pod_identity() {
    log "=========================================="
    log "Setting up S3 CSI Driver with Pod Identity"
    log "=========================================="

    local bucket_arns="$1"
    local role_name="${CLUSTER_NAME}-s3-csi-driver-role"
    local policy_name="${CLUSTER_NAME}-S3CSIDriverPolicy"
    local namespace="kube-system"
    local service_account="s3-csi-driver-sa"

    if [ -z "$bucket_arns" ]; then
        error "S3 bucket ARNs are required for S3 CSI Driver setup"
    fi

    # 转换逗号分隔的 ARNs 为 JSON 数组，并检测 S3 Express One Zone buckets
    local bucket_resources=""
    local object_resources=""
    local s3express_resources=""
    local s3express_object_resources=""
    local has_s3express=false

    IFS=',' read -ra ARNS <<< "$bucket_arns"
    for arn in "${ARNS[@]}"; do
        arn=$(echo "$arn" | xargs) # trim whitespace

        # 检测是否为 S3 Express One Zone bucket (directory bucket)
        if [[ "$arn" == *"s3express"* ]] || [[ "$arn" == *"--x-s3"* ]]; then
            log "Detected S3 Express One Zone bucket: ${arn}"
            s3express_resources="${s3express_resources}\"${arn}\","
            s3express_object_resources="${s3express_object_resources}\"${arn}/*\","
            has_s3express=true
        else
            bucket_resources="${bucket_resources}\"${arn}\","
            object_resources="${object_resources}\"${arn}/*\","
        fi
    done
    bucket_resources=${bucket_resources%,}
    object_resources=${object_resources%,}
    s3express_resources=${s3express_resources%,}
    s3express_object_resources=${s3express_object_resources%,}

    # 构建策略文档
    local policy_statements=""

    # 标准 S3 权限
    if [ -n "$bucket_resources" ]; then
        policy_statements+='
    {
      "Sid": "MountpointListBuckets",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ['"${bucket_resources}"']
    },
    {
      "Sid": "MountpointObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": ['"${object_resources}"']
    }'
    fi

    # S3 Express One Zone 权限
    if [ "$has_s3express" = true ]; then
        [ -n "$policy_statements" ] && policy_statements+=","
        policy_statements+='
    {
      "Sid": "S3ExpressCreateSession",
      "Effect": "Allow",
      "Action": ["s3express:CreateSession"],
      "Resource": ['"${s3express_resources}"']
    },
    {
      "Sid": "S3ExpressListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ['"${s3express_resources}"']
    },
    {
      "Sid": "S3ExpressObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": ['"${s3express_object_resources}"']
    }'
        log "✓ Added S3 Express One Zone (CreateSession + Object Access) permissions"
    fi

    # 创建完整策略文档
    local policy_doc=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [${policy_statements}
  ]
}
EOF
)

    log "S3 CSI Driver policy for buckets: ${bucket_arns}"

    # 1. 创建 IAM 角色
    create_pod_identity_role "${role_name}"

    # 2. 创建和附加自定义策略
    attach_custom_policy "${role_name}" "${policy_name}" "${policy_doc}"

    # 3. 创建 ServiceAccount
    create_service_account "${namespace}" "${service_account}"

    # 4. 创建 Pod Identity Association
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ S3 CSI Driver Pod Identity setup complete"
}

# ============================================
# 辅助函数
# ============================================

# 等待 EKS Addon 就绪
# 参数: $1 = addon_name, $2 = max_attempts (可选，默认60), $3 = interval (可选，默认5)
wait_for_eks_addon() {
    local addon_name="$1"
    local max_attempts="${2:-60}"
    local interval="${3:-5}"

    if [ -z "$addon_name" ]; then
        error "Addon name is required"
    fi

    log "Waiting for ${addon_name} addon to be active..."

    for i in $(seq 1 $max_attempts); do
        local addon_status
        addon_status=$(aws eks describe-addon \
            --cluster-name "${CLUSTER_NAME}" \
            --addon-name "${addon_name}" \
            --region "${AWS_REGION}" \
            --query 'addon.status' \
            --output text 2>/dev/null)

        case "$addon_status" in
            ACTIVE)
                log "✓ ${addon_name} addon is ACTIVE"
                return 0
                ;;
            CREATE_FAILED|UPDATE_FAILED)
                warn "${addon_name} addon failed with status: $addon_status"
                aws eks describe-addon \
                    --cluster-name "${CLUSTER_NAME}" \
                    --addon-name "${addon_name}" \
                    --region "${AWS_REGION}" \
                    --query 'addon.health' 2>/dev/null || true
                return 1
                ;;
            DEGRADED)
                # DEGRADED is transient: addon was created before nodes
                # existed (common with eksctl's --install-addons=true
                # path in script 4) and EKS hasn't yet observed the
                # newly-scheduled pods. Keep polling — it resolves to
                # ACTIVE once the control plane reconciles. Only bail
                # if it stays DEGRADED for the full window.
                echo "  Waiting... (Status: DEGRADED, transient, attempt $i/$max_attempts)"
                sleep $interval
                ;;
            *)
                echo "  Waiting... (Status: $addon_status, attempt $i/$max_attempts)"
                sleep $interval
                ;;
        esac
    done

    warn "Timeout waiting for ${addon_name} addon (max ${max_attempts} attempts)"
    return 1
}

# 列出所有 Pod Identity Associations
list_pod_identity_associations() {
    log "=========================================="
    log "Pod Identity Associations for cluster: ${CLUSTER_NAME}"
    log "=========================================="

    aws eks list-pod-identity-associations \
        --cluster-name "${CLUSTER_NAME}" \
        --query 'associations[].[namespace,serviceAccount,associationArn]' \
        --output table
}

# 验证 Pod Identity 设置
# 参数: $1 = namespace, $2 = service_account
verify_pod_identity() {
    local namespace="${1:-kube-system}"
    local service_account="${2}"

    if [ -z "$service_account" ]; then
        error "Service account name is required for verification"
    fi

    log "Verifying Pod Identity for ${namespace}/${service_account}"

    # 检查 ServiceAccount
    if kubectl get serviceaccount "${service_account}" -n "${namespace}" &>/dev/null; then
        log "✓ ServiceAccount exists"
    else
        error "ServiceAccount does not exist"
    fi

    # 检查 Pod Identity Association
    local association_id=$(aws eks list-pod-identity-associations \
        --cluster-name "${CLUSTER_NAME}" \
        --namespace "${namespace}" \
        --service-account "${service_account}" \
        --query 'associations[0].associationId' \
        --output text 2>/dev/null)

    if [ -n "$association_id" ] && [ "$association_id" != "None" ]; then
        log "✓ Pod Identity Association exists (ID: ${association_id})"

        # 获取详细信息
        aws eks describe-pod-identity-association \
            --cluster-name "${CLUSTER_NAME}" \
            --association-id "${association_id}" \
            --query '{RoleArn:roleArn,Status:status}' \
            --output table
    else
        error "Pod Identity Association does not exist"
    fi
}

# 清理 Pod Identity（谨慎使用）
# 参数: $1 = namespace, $2 = service_account, $3 = role_name
cleanup_pod_identity() {
    local namespace="$1"
    local service_account="$2"
    local role_name="$3"

    warn "Cleaning up Pod Identity for ${namespace}/${service_account}"

    # 删除 Pod Identity Association
    local association_id=$(aws eks list-pod-identity-associations \
        --cluster-name "${CLUSTER_NAME}" \
        --namespace "${namespace}" \
        --service-account "${service_account}" \
        --query 'associations[0].associationId' \
        --output text 2>/dev/null)

    if [ -n "$association_id" ] && [ "$association_id" != "None" ]; then
        log "Deleting Pod Identity Association: ${association_id}"
        aws eks delete-pod-identity-association \
            --cluster-name "${CLUSTER_NAME}" \
            --association-id "${association_id}" &>/dev/null
    fi

    # 删除 IAM 角色（如果提供）
    if [ -n "$role_name" ]; then
        log "Detaching policies from role: ${role_name}"
        aws iam list-attached-role-policies --role-name "${role_name}" \
            --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null | \
            xargs -I {} aws iam detach-role-policy --role-name "${role_name}" --policy-arn {} 2>/dev/null || true

        log "Deleting IAM role: ${role_name}"
        aws iam delete-role --role-name "${role_name}" &>/dev/null || true
    fi

    log "Cleanup complete"
}

# ============================================
# 脚本结束时的说明
# ============================================

# 如果直接运行此脚本（而不是 source），显示帮助信息
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    cat <<EOF
Pod Identity Helper Functions

This script provides reusable functions for setting up Pod Identity for EKS add-ons.

Usage:
  source ${BASH_SOURCE[0]}

Functions:
  Core Functions:
    - create_pod_identity_role <role_name>
    - attach_managed_policy <role_name> <policy_arn>
    - attach_custom_policy <role_name> <policy_name> <policy_document>
    - create_pod_identity_association <namespace> <service_account> <role_name>
    - wait_for_pod_identity_agent
    - create_service_account <namespace> <service_account>

  Component Setup Functions:
    - setup_cluster_autoscaler_pod_identity
    - setup_ebs_csi_pod_identity
    - setup_alb_controller_pod_identity
    - setup_efs_csi_pod_identity
    - setup_fsx_csi_pod_identity
    - setup_s3_csi_pod_identity <bucket_arns>

  Utility Functions:
    - wait_for_eks_addon <addon_name> [max_attempts] [interval]
    - list_pod_identity_associations
    - verify_pod_identity <namespace> <service_account>
    - cleanup_pod_identity <namespace> <service_account> <role_name>

Example:
  source scripts/0_setup_env.sh
  source scripts/legacy/pod_identity_helpers.sh
  setup_cluster_autoscaler_pod_identity

Requirements:
  - AWS CLI configured with appropriate permissions
  - kubectl configured for the cluster
  - Environment variables: CLUSTER_NAME, ACCOUNT_ID
EOF
fi
