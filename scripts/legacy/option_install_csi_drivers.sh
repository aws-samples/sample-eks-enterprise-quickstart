#!/bin/bash

set -e
set -o pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "==========================================="
echo "Optional CSI Drivers Installation (EKS Managed Addons)"
echo "==========================================="
echo ""

# 加载环境变量和 helper 函数
source "${SCRIPT_DIR}/../0_setup_env.sh"

# 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME:-/root}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 验证集群存在并更新 kubeconfig
echo "Verifying EKS cluster exists and updating kubeconfig..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "❌ ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    exit 1
fi

# 验证 kubectl context（使用统一函数）
verify_kubectl_context
echo ""

# ============================================
# CSI Driver 安装函数（使用 EKS Managed Addon）
# ============================================

# 安装 EBS CSI Driver Addon + StorageClass
install_ebs_csi_addon() {
    echo ""
    echo "=========================================="
    echo "Installing EBS CSI Driver (EKS Managed Addon)"
    echo "=========================================="
    echo ""

    local addon_name="aws-ebs-csi-driver"
    local role_name="${CLUSTER_NAME}-ebs-csi-driver-role"
    local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"

    # 1. 设置 Pod Identity
    setup_ebs_csi_pod_identity

    # 2. 创建 addon 配置 (只用 nodeSelector，使用默认 affinity)
    local config_file=$(mktemp /tmp/ebs-csi-config.XXXXXX.json)
    cat > "${config_file}" <<EOF
{
  "controller": {
    "replicaCount": 2,
    "nodeSelector": {
      "${SYSTEM_NODE_LABEL_KEY}": "${SYSTEM_NODE_LABEL_VALUE}"
    }
  }
}
EOF

    # 3. 安装或更新 addon
    if aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${addon_name} --region ${AWS_REGION} &>/dev/null; then
        echo "EBS CSI Driver addon already exists, updating..."
        aws eks update-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --configuration-values "file://${config_file}" \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE || echo "Update may have failed, but continuing..."
    else
        echo "Creating EBS CSI Driver addon..."
        aws eks create-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --configuration-values "file://${config_file}" \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE
    fi

    rm -f "${config_file}"

    # 4. 等待 addon 就绪
    wait_for_eks_addon "${addon_name}"

    # 5. 清理 IRSA annotation（确保使用 Pod Identity）
    echo "Ensuring Pod Identity is used (removing any IRSA annotation)..."
    kubectl annotate sa -n kube-system ebs-csi-controller-sa eks.amazonaws.com/role-arn- --overwrite 2>/dev/null || true

    # 6. 创建 StorageClass (gp3, io2)
    echo ""
    echo "Creating StorageClasses (gp3, io2)..."
    sed -e "s/\${IO2_IOPS}/${IO2_IOPS}/g" \
        "${SCRIPT_DIR}/manifests/storage/storageclass.yaml" | kubectl apply -f -

    # 7. 删除旧的 gp2 StorageClass (only after gp3 is confirmed ready)
    if kubectl get storageclass gp3 &>/dev/null; then
        if kubectl get storageclass gp2 &>/dev/null; then
            echo "gp3 StorageClass confirmed, removing deprecated gp2..."
            kubectl delete storageclass gp2 || echo "Warning: Failed to delete gp2"
        fi
    else
        echo "Warning: gp3 StorageClass not found, keeping gp2 as fallback"
    fi

    # 8. 验证
    echo ""
    echo "Verifying EBS CSI Driver installation..."
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

    echo ""
    echo "StorageClasses:"
    kubectl get storageclass

    echo ""
    echo "✓ EBS CSI Driver installed successfully!"
    echo ""
    echo "StorageClasses available:"
    echo "  - gp3 (default): General purpose SSD, 3000 IOPS baseline"
    echo "  - io2: High-performance SSD, ${IO2_IOPS} IOPS"
    echo ""
}

# 安装 EFS CSI Driver Addon
install_efs_csi_addon() {
    echo ""
    echo "=========================================="
    echo "Installing EFS CSI Driver (EKS Managed Addon)"
    echo "=========================================="
    echo ""

    local addon_name="aws-efs-csi-driver"
    local role_name="${CLUSTER_NAME}-efs-csi-driver-role"
    local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"

    # 1. 设置 Pod Identity
    setup_efs_csi_pod_identity

    # 2. 创建 addon 配置 (EFS addon schema 不支持 affinity，只支持 nodeSelector/tolerations)
    local config_file=$(mktemp /tmp/efs-csi-config.XXXXXX.json)
    cat > "${config_file}" <<EOF
{
  "controller": {
    "replicaCount": 2,
    "nodeSelector": {
      "${SYSTEM_NODE_LABEL_KEY}": "${SYSTEM_NODE_LABEL_VALUE}"
    }
  }
}
EOF

    # 3. 安装或更新 addon
    if aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${addon_name} --region ${AWS_REGION} &>/dev/null; then
        echo "EFS CSI Driver addon already exists, updating..."
        aws eks update-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --configuration-values "file://${config_file}" \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE || echo "Update may have failed, but continuing..."
    else
        echo "Creating EFS CSI Driver addon..."
        aws eks create-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --configuration-values "file://${config_file}" \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE
    fi

    rm -f "${config_file}"

    # 4. 等待 addon 就绪
    wait_for_eks_addon "${addon_name}"

    # 5. 清理 IRSA annotation（确保使用 Pod Identity）
    echo "Ensuring Pod Identity is used (removing any IRSA annotation)..."
    kubectl annotate sa -n kube-system efs-csi-controller-sa eks.amazonaws.com/role-arn- --overwrite 2>/dev/null || true

    # 6. 验证
    echo ""
    echo "Verifying EFS CSI Driver installation..."
    kubectl get pods -n kube-system -l app=efs-csi-controller

    echo ""
    echo "✓ EFS CSI Driver installed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Create an EFS file system: aws efs create-file-system --region ${AWS_REGION}"
    echo "  2. Create mount targets in your VPC subnets"
    echo "  3. Create a StorageClass and PVC (see examples/efs-app.yaml)"
    echo ""
}

# 安装 FSx CSI Driver Addon
install_fsx_csi_addon() {
    echo ""
    echo "=========================================="
    echo "Installing FSx CSI Driver (EKS Managed Addon)"
    echo "=========================================="
    echo ""

    local addon_name="aws-fsx-csi-driver"
    local role_name="${CLUSTER_NAME}-fsx-csi-driver-role"
    local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"

    # 1. 设置 Pod Identity（使用自定义 policy）
    setup_fsx_csi_pod_identity

    # 2. 创建 addon 配置 (只用 nodeSelector，使用默认 affinity)
    local config_file=$(mktemp /tmp/fsx-csi-config.XXXXXX.json)
    cat > "${config_file}" <<EOF
{
  "controller": {
    "replicaCount": 2,
    "nodeSelector": {
      "${SYSTEM_NODE_LABEL_KEY}": "${SYSTEM_NODE_LABEL_VALUE}"
    }
  }
}
EOF

    # 3. 安装或更新 addon
    if aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${addon_name} --region ${AWS_REGION} &>/dev/null; then
        echo "FSx CSI Driver addon already exists, updating..."
        aws eks update-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --configuration-values "file://${config_file}" \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE || echo "Update may have failed, but continuing..."
    else
        echo "Creating FSx CSI Driver addon..."
        aws eks create-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --configuration-values "file://${config_file}" \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE
    fi

    rm -f "${config_file}"

    # 4. 等待 addon 就绪
    wait_for_eks_addon "${addon_name}"

    # 5. 清理 IRSA annotation
    echo "Ensuring Pod Identity is used (removing any IRSA annotation)..."
    kubectl annotate sa -n kube-system fsx-csi-controller-sa eks.amazonaws.com/role-arn- --overwrite 2>/dev/null || true

    # 6. 验证
    echo ""
    echo "Verifying FSx CSI Driver installation..."
    kubectl get pods -n kube-system -l app=fsx-csi-controller

    echo ""
    echo "✓ FSx CSI Driver installed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Create FSx for Lustre or ONTAP file system"
    echo "  2. Create a StorageClass with FSx parameters"
    echo "  3. Create PVC and mount in your workloads"
    echo ""
    echo "Supported FSx types:"
    echo "  - FSx for Lustre: High-performance for HPC/ML (GB/s throughput)"
    echo "  - FSx for NetApp ONTAP: Enterprise features (snapshots, replication)"
    echo ""
    echo "⚠️  IMPORTANT: FSx Lustre DeploymentType compatibility"
    echo "   Use PERSISTENT_2 (Lustre 2.15), NOT SCRATCH_2 (Lustre 2.10)."
    echo "   AL2023's lustre-client package is 2.15.x and will fail to"
    echo "   mount a 2.10 server with:"
    echo "     mount.lustre: mount ... failed: Invalid argument"
    echo "     LustreError: 16a-d: Server MGS version (2.10.5.0) refused"
    echo "     connection from this client with an incompatible version"
    echo "     (2.15.6). Client must be recompiled"
    echo "   Example create command:"
    echo "     aws fsx create-file-system --file-system-type LUSTRE \\"
    echo "       --storage-capacity 1200 \\"
    echo "       --lustre-configuration DeploymentType=PERSISTENT_2,PerUnitStorageThroughput=125"
    echo ""
}

# 安装 S3 CSI Driver Addon
install_s3_csi_addon() {
    local bucket_arns="$1"

    echo ""
    echo "=========================================="
    echo "Installing S3 CSI Driver (EKS Managed Addon)"
    echo "=========================================="
    echo ""

    if [ -z "$bucket_arns" ]; then
        echo "S3 CSI Driver requires S3 bucket permissions."
        echo ""
        echo "IMPORTANT: You need to specify S3 bucket ARNs for access."
        echo ""
        echo "Supported bucket types:"
        echo "  1. Standard S3: arn:aws:s3:::bucket-name"
        echo "  2. S3 Express One Zone: arn:aws:s3express:region:account:bucket/bucket-name--zone-id--x-s3"
        echo ""
        echo "Examples:"
        echo "  - Standard: arn:aws:s3:::my-data-bucket"
        echo "  - S3 Express: arn:aws:s3express:us-east-1:123456789012:bucket/my-bucket--use1-az1--x-s3"
        echo ""

        read -p "Enter S3 bucket ARN(s) (comma-separated if multiple): " bucket_arns
    fi

    if [ -z "$bucket_arns" ]; then
        echo "❌ ERROR: No bucket ARNs provided. Exiting."
        return 1
    fi

    local addon_name="aws-mountpoint-s3-csi-driver"
    local role_name="${CLUSTER_NAME}-s3-csi-driver-role"
    local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"

    # 1. 设置 Pod Identity（使用动态 bucket policy）
    setup_s3_csi_pod_identity "$bucket_arns"

    # 2. 安装或更新 addon (S3 CSI Driver 不支持自定义配置)
    if aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${addon_name} --region ${AWS_REGION} &>/dev/null; then
        echo "S3 CSI Driver addon already exists, updating..."
        aws eks update-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE || echo "Update may have failed, but continuing..."
    else
        echo "Creating S3 CSI Driver addon..."
        aws eks create-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name ${addon_name} \
            --service-account-role-arn ${role_arn} \
            --region ${AWS_REGION} \
            --resolve-conflicts OVERWRITE
    fi

    # 4. 等待 addon 就绪
    wait_for_eks_addon "${addon_name}"

    # 5. 清理 IRSA annotation
    echo "Ensuring Pod Identity is used (removing any IRSA annotation)..."
    kubectl annotate sa -n kube-system s3-csi-driver-sa eks.amazonaws.com/role-arn- --overwrite 2>/dev/null || true

    # 6. 验证
    echo ""
    echo "Verifying S3 CSI Driver installation..."
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver

    echo ""
    echo "✓ S3 CSI Driver installed successfully!"
    echo ""
    echo "Bucket ARNs configured:"
    IFS=',' read -ra ARNS <<< "$bucket_arns"
    for arn in "${ARNS[@]}"; do
        echo "  - ${arn}"
    done
    echo ""
    echo "Next steps:"
    echo "  1. Create a PersistentVolume pointing to your S3 bucket"
    echo "  2. Create a PVC and mount it in your Pod"
    echo "  3. See examples/s3-app.yaml for examples"
    echo ""
}

# ============================================
# 主菜单
# ============================================

# 支持非交互模式: INSTALL_DRIVERS=ebs|efs|fsx|s3|all S3_BUCKET_ARNS=arn:aws:s3:::bucket1
INSTALL_DRIVERS="${INSTALL_DRIVERS:-}"
S3_BUCKET_ARNS="${S3_BUCKET_ARNS:-}"

if [ -z "$INSTALL_DRIVERS" ]; then
    echo "This script installs CSI drivers as EKS Managed Addons."
    echo ""
    echo "For non-interactive mode, set environment variables:"
    echo "  INSTALL_DRIVERS=ebs|efs|fsx|s3|all"
    echo "  S3_BUCKET_ARNS='arn:aws:s3:::bucket1,arn:aws:s3:::bucket2' (for S3 driver)"
    echo ""
    echo "Available drivers (EKS Managed Addons):"
    echo "  1. EBS CSI Driver - Block storage (gp3/io2 StorageClass)"
    echo "  2. EFS CSI Driver - Shared file system (multi-AZ, multi-Pod access)"
    echo "  3. FSx CSI Driver - High-performance Lustre/ONTAP for HPC/ML workloads"
    echo "  4. S3 CSI Driver - Object storage mounting via Mountpoint for S3"
    echo "  5. Install All (EBS + EFS + FSx + S3)"
    echo "  6. Exit"
    echo ""

    read -p "Select option (1-6): " choice
else
    case "$INSTALL_DRIVERS" in
        ebs) choice=1 ;;
        efs) choice=2 ;;
        fsx) choice=3 ;;
        s3) choice=4 ;;
        all) choice=5 ;;
        *)
            echo "❌ ERROR: Invalid INSTALL_DRIVERS value: $INSTALL_DRIVERS"
            echo "Valid values: ebs, efs, fsx, s3, all"
            exit 1
            ;;
    esac
    echo "Running in non-interactive mode: INSTALL_DRIVERS=$INSTALL_DRIVERS"
fi

case $choice in
    1)
        install_ebs_csi_addon
        ;;

    2)
        install_efs_csi_addon
        ;;

    3)
        install_fsx_csi_addon
        ;;

    4)
        install_s3_csi_addon "$S3_BUCKET_ARNS"
        ;;

    5)
        echo ""
        echo "=========================================="
        echo "Installing All CSI Drivers (EBS + EFS + FSx + S3)"
        echo "=========================================="
        echo ""

        # EBS
        echo "Step 1/4: Installing EBS CSI Driver..."
        install_ebs_csi_addon

        # EFS
        echo "Step 2/4: Installing EFS CSI Driver..."
        install_efs_csi_addon

        # FSx
        echo "Step 3/4: Installing FSx CSI Driver..."
        install_fsx_csi_addon

        # S3
        echo "Step 4/4: Installing S3 CSI Driver..."
        if [ -z "$S3_BUCKET_ARNS" ]; then
            echo "Enter S3 bucket ARN(s) for the S3 CSI Driver:"
            echo "  - Standard S3: arn:aws:s3:::bucket-name"
            echo "  - S3 Express: arn:aws:s3express:region:account:bucket/bucket-name--zone-id--x-s3"
            read -p "Bucket ARN(s) (comma-separated, or leave empty to skip): " S3_BUCKET_ARNS
        fi

        if [ -z "$S3_BUCKET_ARNS" ]; then
            echo "Warning: No bucket ARNs provided. Skipping S3 CSI Driver."
        else
            install_s3_csi_addon "$S3_BUCKET_ARNS"
        fi

        echo ""
        echo "✓ All requested drivers installed!"
        ;;

    6)
        echo "Exiting without installing any drivers."
        exit 0
        ;;

    *)
        echo "Invalid selection. Exiting."
        exit 1
        ;;
esac

echo "==========================================="
echo "Installation Complete"
echo "==========================================="
echo ""
echo "To verify EKS Addons:"
echo "  aws eks list-addons --cluster-name ${CLUSTER_NAME}"
echo ""
echo "To verify Pod Identity Associations:"
echo "  aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME}"
echo ""
echo "To check CSI driver pods:"
echo "  kubectl get pods -n kube-system | grep csi"
echo ""
