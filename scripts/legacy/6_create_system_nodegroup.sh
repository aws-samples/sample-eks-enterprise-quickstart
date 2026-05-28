#!/bin/bash

set -e
set -o pipefail

# Disable AWS CLI pager to prevent blocking on JSON output
export AWS_PAGER=""

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "=== Create System Nodegroup with LVM Configuration ==="
echo ""
echo "This script will create a system nodegroup with LVM configuration:"
echo "  • Instance Type: configured in .env (default: m8g.xlarge)"
echo "  • Root Volume: 50GB gp3"
echo "  • Data Volume: 100GB gp3 (for containerd with LVM)"
echo "  • Desired Capacity: 3 nodes"
echo ""
echo "Benefits:"
echo "  ✓ Larger containerd storage (100GB vs 50GB)"
echo "  ✓ Better I/O performance with dedicated data volume"
echo "  ✓ Ready for production workloads"
echo ""
echo "⏱  Expected duration: 8-12 minutes"
echo ""

# 1. 设置环境变量
source "${SCRIPT_DIR}/../0_setup_env.sh"

# Load instance architecture detection helpers (detect_instance_arch,
# instance_arch_to_go_arch). Queries the EC2 API so we never miss new
# Graviton / GPU families that break string-matching heuristics.
source "${SCRIPT_DIR}/instance_arch_lib.sh"
declare -F detect_instance_arch >/dev/null || {
    echo "❌ ERROR: instance_arch_lib.sh did not export detect_instance_arch()" >&2
    exit 1
}

# Load NVMe data-disk detection snippet for user-data. Distinguishes EBS
# from Instance Store via device model, so families like *d / *gd that
# expose unpartitioned ephemeral NVMe disks don't silently win the
# "first nvme without partitions" race against the real EBS data disk.
source "${SCRIPT_DIR}/disk_detection_lib.sh"
if [ -z "${EBS_DATA_DISK_DETECT_SNIPPET:-}" ]; then
    echo "❌ ERROR: disk_detection_lib.sh did not export EBS_DATA_DISK_DETECT_SNIPPET" >&2
    echo "   The data-disk detection snippet would be empty in user-data, breaking LVM setup." >&2
    exit 1
fi

# 1.1 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME:-/root}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.2. 检查必需的依赖工具
echo ""
echo "Checking required dependencies..."
MISSING_DEPS=()

command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v eksctl >/dev/null 2>&1 || MISSING_DEPS+=("eksctl")
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

# 2. 验证集群存在
echo "Verifying EKS cluster exists..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "❌ ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    echo "Please run script 4_install_eks_cluster.sh first to create the cluster."
    exit 1
fi

# 2.0 检测集群 API 可达性（私有集群需从 VPC 内部访问）
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.endpoint' --output text)
echo "Checking API endpoint reachability: ${CLUSTER_ENDPOINT}..."
if ! timeout 10 curl -sk "${CLUSTER_ENDPOINT}/healthz" >/dev/null 2>&1; then
    echo "❌ ERROR: Cannot reach cluster API at ${CLUSTER_ENDPOINT}"
    echo ""
    echo "This is a private cluster (publicAccess: false)."
    echo "You must run this script from within the cluster's VPC."
    echo "Options:"
    echo "  1. Run from a bastion host in the same VPC: ./scripts/option_create_bastion.sh"
    echo "  2. Run from an EC2 instance with VPC Peering to the cluster VPC"
    exit 1
fi
echo "✓ Cluster API is reachable"

# 验证 kubectl context（使用统一函数）
verify_kubectl_context
echo ""

# 2.1 配置安全组以允许访问集群 API (针对私有集群)
# 支持两种场景：1) 同VPC堡垒机 2) 跨VPC/VPC Peering
echo "Configuring security group for API access..."

# 获取集群安全组
CLUSTER_SG=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --region ${AWS_REGION} \
    --query 'cluster.resourcesVpcConfig.securityGroupIds[0]' \
    --output text 2>/dev/null)

if [ -z "${CLUSTER_SG}" ] || [ "${CLUSTER_SG}" = "None" ]; then
    echo "❌ ERROR: Could not get cluster security group"
    exit 1
fi

echo "Cluster Security Group: ${CLUSTER_SG}"

# 尝试获取EC2元数据（使用IMDSv2）
echo "Detecting execution environment..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s --connect-timeout 2 2>/dev/null || echo "")

if [ -n "${TOKEN}" ]; then
    INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id --connect-timeout 2 2>/dev/null || echo "")
    INSTANCE_VPC_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/mac --connect-timeout 2)/vpc-id --connect-timeout 2 2>/dev/null || echo "")
fi

# 获取集群VPC ID
CLUSTER_VPC_ID=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --region ${AWS_REGION} \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text 2>/dev/null)

echo "Cluster VPC: ${CLUSTER_VPC_ID}"

if [ -n "${INSTANCE_ID}" ] && [ -n "${INSTANCE_VPC_ID}" ]; then
    echo "Running on EC2 instance: ${INSTANCE_ID}"
    echo "Instance VPC: ${INSTANCE_VPC_ID}"

    if [ "${INSTANCE_VPC_ID}" = "${CLUSTER_VPC_ID}" ]; then
        # 场景1：同VPC堡垒机 - 使用安全组规则
        echo "Mode: Same VPC (bastion mode)"

        BASTION_SG=$(aws ec2 describe-instances \
            --instance-ids ${INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
            --output text \
            --region ${AWS_REGION} 2>/dev/null)

        if [ -n "${BASTION_SG}" ] && [ "${BASTION_SG}" != "None" ]; then
            echo "Bastion Security Group: ${BASTION_SG}"
            echo "Adding security group rule..."
            sg_result=""
            if sg_result=$(aws ec2 authorize-security-group-ingress \
                --group-id ${CLUSTER_SG} \
                --protocol tcp \
                --port 443 \
                --source-group ${BASTION_SG} \
                --region ${AWS_REGION} 2>&1); then
                echo "✓ Security group rule added successfully"
            elif echo "${sg_result}" | grep -q "already exists"; then
                echo "✓ Security group rule already exists"
            else
                echo "ERROR: Failed to add security group rule: ${sg_result}"
                exit 1
            fi
        fi
    else
        # 场景2：跨VPC (VPC Peering) - 使用CIDR规则
        echo "Mode: Cross-VPC (VPC Peering mode)"

        # 获取当前实例所在VPC的CIDR
        # 需要查询实例所在区域的VPC
        INSTANCE_REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/region --connect-timeout 2 2>/dev/null || echo "")

        if [ -n "${INSTANCE_REGION}" ]; then
            INSTANCE_VPC_CIDR=$(aws ec2 describe-vpcs \
                --vpc-ids ${INSTANCE_VPC_ID} \
                --region ${INSTANCE_REGION} \
                --query 'Vpcs[0].CidrBlock' \
                --output text 2>/dev/null)

            if [ -n "${INSTANCE_VPC_CIDR}" ] && [ "${INSTANCE_VPC_CIDR}" != "None" ]; then
                echo "Instance VPC CIDR: ${INSTANCE_VPC_CIDR}"
                echo "Adding CIDR-based security group rule..."
                sg_cidr_result=""
                if sg_cidr_result=$(aws ec2 authorize-security-group-ingress \
                    --group-id ${CLUSTER_SG} \
                    --protocol tcp \
                    --port 443 \
                    --cidr ${INSTANCE_VPC_CIDR} \
                    --region ${AWS_REGION} 2>&1); then
                    echo "✓ Security group rule added for VPC CIDR ${INSTANCE_VPC_CIDR}"
                elif echo "${sg_cidr_result}" | grep -q "already exists"; then
                    echo "✓ Security group rule already exists"
                else
                    echo "ERROR: Failed to add CIDR security group rule: ${sg_cidr_result}"
                    exit 1
                fi
            fi
        fi
    fi
else
    # 非EC2环境或无法获取元数据 - 跳过安全组配置
    echo "⚠ WARNING: Not running on EC2 or cannot detect environment"
    echo "  Skipping automatic security group configuration"
    echo "  Please ensure EKS API is accessible from your network"
fi

echo "✓ Security group configuration complete"
echo ""

# ===================================================================
# 系统节点组创建函数（带LVM配置）
# ===================================================================

# 创建EKS节点IAM Role和Instance Profile
create_eks_node_iam_role() {
    NODE_ROLE_NAME="EKSNodeRole-${CLUSTER_NAME}"
    INSTANCE_PROFILE_NAME="${NODE_ROLE_NAME}"

    # 检查 IAM Role 是否已存在（幂等性）
    if aws iam get-role --role-name "${NODE_ROLE_NAME}" &>/dev/null; then
        echo "✓ IAM Role ${NODE_ROLE_NAME} already exists, skipping creation"
    else
        echo "Creating IAM Role: ${NODE_ROLE_NAME}"

        # 创建信任策略（使用 mktemp 避免临时文件冲突）
        local TRUST_POLICY_FILE
        TRUST_POLICY_FILE=$(mktemp /tmp/node-trust-policy.XXXXXX.json)
        trap "rm -f ${TRUST_POLICY_FILE}" RETURN

        cat > "${TRUST_POLICY_FILE}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

        aws iam create-role \
            --role-name "${NODE_ROLE_NAME}" \
            --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
            --tags \
                Key=Cluster,Value="${CLUSTER_NAME}" \
                Key=ManagedBy,Value=script \
                Key=business,Value=middleware \
                Key=resource,Value=eks

        rm -f "${TRUST_POLICY_FILE}"
        echo "✓ IAM Role created"
    fi

    # Always ensure required policies are attached (idempotent)
    echo "Ensuring required policies are attached to ${NODE_ROLE_NAME}..."

    aws iam attach-role-policy \
        --role-name "${NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" 2>/dev/null || true

    aws iam attach-role-policy \
        --role-name "${NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" 2>/dev/null || true

    aws iam attach-role-policy \
        --role-name "${NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" 2>/dev/null || true

    aws iam attach-role-policy \
        --role-name "${NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true

    # Add ec2:DescribeInstances permission required by nodeadm (K8s 1.34+)
    aws iam put-role-policy \
        --role-name "${NODE_ROLE_NAME}" \
        --policy-name "NodeadmDescribeInstances" \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
                "Resource": "*"
            }]
        }'

    echo "✓ IAM Role policies verified"

    # 检查 Instance Profile 是否已存在（幂等性）
    if aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" &>/dev/null; then
        echo "✓ Instance Profile ${INSTANCE_PROFILE_NAME} already exists, skipping creation"
    else
        echo "Creating Instance Profile: ${INSTANCE_PROFILE_NAME}"

        aws iam create-instance-profile \
            --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
            --tags \
                Key=Cluster,Value="${CLUSTER_NAME}" \
                Key=ManagedBy,Value=script \
                Key=business,Value=middleware \
                Key=resource,Value=eks

        aws iam add-role-to-instance-profile \
            --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
            --role-name "${NODE_ROLE_NAME}"

        # 等待 Instance Profile 创建完成
        echo "Waiting for Instance Profile to be ready..."
        sleep 10

        echo "✓ Instance Profile created"
    fi

    INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile \
        --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
        --query 'InstanceProfile.Arn' \
        --output text)

    echo "Instance Profile ARN: ${INSTANCE_PROFILE_ARN}"
}

# 创建包含LVM设置和NodeConfig的user-data
create_lvm_userdata() {
    USERDATA_FILE="/tmp/eks-utils-userdata-$$.txt"
    cat > "${USERDATA_FILE}" <<EOF_USERDATA
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM Setup - executed before EKS bootstrap
set -ex

# Log to file for debugging
exec > >(tee /var/log/lvm-setup.log)
exec 2>&1

echo "=== Starting LVM Setup ==="

# Stop containerd
systemctl stop containerd || true

# Wait for EBS data disk to be available (max 60 seconds).
# Must distinguish EBS from Instance Store by device model, because families
# like m6gd / m7gd expose ephemeral NVMe that also has no partitions.
${EBS_DATA_DISK_DETECT_SNIPPET}

echo "Waiting for EBS data disk..."
DISK=\$(detect_ebs_data_disk 60) || {
  echo "ERROR: No EBS data disk found after 60 seconds"
  echo "Available disks:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
  systemctl start containerd
  exit 1
}
echo "Found EBS data disk: \$DISK"

# Check if LVM already configured
if vgs vg_data &>/dev/null; then
  echo "LVM already configured, mounting..."
  mount /dev/vg_data/lv_containerd /var/lib/containerd || true
  systemctl start containerd
else
  # Install lvm2 and rsync
  echo "Installing lvm2 and rsync..."
  dnf install -y lvm2 rsync

  # Create LVM
  echo "Creating LVM on \$DISK..."
  pvcreate "\$DISK"
  vgcreate vg_data "\$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd

  # Mount and migrate data (including pre-cached images from AMI)
  echo "Mounting and migrating containerd data..."
  mkdir -p /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /mnt/runtime/containerd

  echo "Copying containerd data (including pre-cached pause image) from AMI..."
  rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true

  echo "Unmounting temporary directory"
  umount /mnt/runtime/containerd

  echo "Mounting LV to final destination: /var/lib/containerd"
  mount /dev/vg_data/lv_containerd /var/lib/containerd

  # Add to fstab
  grep -q "lv_containerd" /etc/fstab || \
    echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

  echo "LVM setup completed successfully"
  df -h /var/lib/containerd
  vgs
  lvs

  # Start containerd
  systemctl start containerd
fi

echo "=== LVM Setup Complete ==="

# Install lustre-client so pods that mount FSx Lustre via the FSx CSI
# driver actually work. Without this, kubelet fails with
# "mount.lustre: ... : Invalid argument" at PVC attach time.
# Best-effort — pod scheduling still works without it.
echo "=== Installing Lustre client (for FSx Lustre CSI) ==="
dnf install -y lustre-client 2>&1 | tail -5 || echo "WARN: lustre-client install failed (FSx Lustre will not work on this node)"
modprobe lustre || true

echo "=== Starting EKS Node Bootstrap ==="

# Create nodeadm config
mkdir -p /etc/eks/nodeadm.d
cat > /etc/eks/nodeadm.d/nodeconfig.yaml <<NODECONFIG
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${SERVICE_IPV4_CIDR}
NODECONFIG

echo "NodeConfig written to /etc/eks/nodeadm.d/nodeconfig.yaml"
cat /etc/eks/nodeadm.d/nodeconfig.yaml

# Run nodeadm init to bootstrap the node
echo "Running nodeadm init..."
nodeadm init --config-source file:///etc/eks/nodeadm.d/nodeconfig.yaml

# Enable services for reboot persistence
echo "Enabling kubelet and containerd services..."
systemctl enable kubelet containerd

echo "=== EKS Node Bootstrap Complete ==="

--==BOUNDARY==--
EOF_USERDATA

    echo "✓ User-data created at: ${USERDATA_FILE}"
}

# 创建Launch Template
create_launch_template() {
    LT_NAME="${CLUSTER_NAME}-eks-utils-lt"

    # 构建可选的 KeyName JSON 片段
    if [[ -n "${EC2_KEY_NAME:-}" ]]; then
        KEY_NAME_JSON="\"KeyName\": \"${EC2_KEY_NAME}\","
        echo "Using EC2 Key Pair: ${EC2_KEY_NAME}"
    else
        KEY_NAME_JSON=""
    fi

    # 检查Launch Template是否已存在（幂等性）
    if aws ec2 describe-launch-templates \
        --launch-template-names "${LT_NAME}" \
        --region "${AWS_REGION}" &>/dev/null; then

        echo "Launch Template ${LT_NAME} already exists, creating new version..."

        LT_ID=$(aws ec2 describe-launch-templates \
            --launch-template-names "${LT_NAME}" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplates[0].LaunchTemplateId' \
            --output text)

        LT_VERSION=$(aws ec2 create-launch-template-version \
            --launch-template-id "${LT_ID}" \
            --launch-template-data "{
              \"ImageId\": \"${AMI_ID}\",
              ${KEY_NAME_JSON}
              \"InstanceType\": \"${SYSTEM_NODE_INSTANCE_TYPE}\",
              \"UserData\": \"$(base64 -w 0 < ${USERDATA_FILE})\",
              \"BlockDeviceMappings\": [
                {
                  \"DeviceName\": \"/dev/xvda\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_ROOT_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                },
                {
                  \"DeviceName\": \"/dev/xvdb\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_DATA_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Iops\": 3000,
                    \"Throughput\": 125,
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                }
              ],
              \"MetadataOptions\": {
                \"HttpEndpoint\": \"enabled\",
                \"HttpTokens\": \"required\",
                \"HttpPutResponseHopLimit\": 2
              },
              \"TagSpecifications\": [
                {
                  \"ResourceType\": \"instance\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-node\"},
                    {\"Key\": \"kubernetes.io/cluster/${CLUSTER_NAME}\", \"Value\": \"owned\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                },
                {
                  \"ResourceType\": \"volume\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-volume\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                }
              ]
            }" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplateVersion.VersionNumber' \
            --output text)

        echo "Created Launch Template version: ${LT_VERSION}"

    else
        echo "Creating new Launch Template: ${LT_NAME}..."

        LT_RESULT=$(aws ec2 create-launch-template \
            --launch-template-name "${LT_NAME}" \
            --launch-template-data "{
              \"ImageId\": \"${AMI_ID}\",
              ${KEY_NAME_JSON}
              \"InstanceType\": \"${SYSTEM_NODE_INSTANCE_TYPE}\",
              \"UserData\": \"$(base64 -w 0 < ${USERDATA_FILE})\",
              \"BlockDeviceMappings\": [
                {
                  \"DeviceName\": \"/dev/xvda\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_ROOT_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                },
                {
                  \"DeviceName\": \"/dev/xvdb\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_DATA_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Iops\": 3000,
                    \"Throughput\": 125,
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                }
              ],
              \"MetadataOptions\": {
                \"HttpEndpoint\": \"enabled\",
                \"HttpTokens\": \"required\",
                \"HttpPutResponseHopLimit\": 2
              },
              \"TagSpecifications\": [
                {
                  \"ResourceType\": \"instance\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-node\"},
                    {\"Key\": \"kubernetes.io/cluster/${CLUSTER_NAME}\", \"Value\": \"owned\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                },
                {
                  \"ResourceType\": \"volume\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-volume\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                }
              ]
            }" \
            --region "${AWS_REGION}" \
            --output json)

        LT_ID=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LaunchTemplateId')
        LT_VERSION=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LatestVersionNumber')

        echo "Created Launch Template: ${LT_ID} (version ${LT_VERSION})"
    fi

    # 清理临时文件
    rm -f "${USERDATA_FILE}"

    echo "Launch Template Information:"
    echo "  Name: ${LT_NAME}"
    echo "  ID: ${LT_ID}"
    echo "  Version: ${LT_VERSION}"
}

# 删除现有系统节点组
delete_existing_nodegroup() {
    echo "Checking for existing system nodegroups..."

    # 检查是否有需要删除的节点组
    NODEGROUPS_TO_DELETE=()
    for NG_NAME in eks-utils eks-utils-arm64 eks-utils-x86; do
        if aws eks describe-nodegroup \
            --cluster-name "${CLUSTER_NAME}" \
            --nodegroup-name "${NG_NAME}" \
            --region "${AWS_REGION}" &>/dev/null; then
            NODEGROUPS_TO_DELETE+=("${NG_NAME}")
            echo "Found nodegroup to delete: ${NG_NAME}"
        fi
    done

    # 如果没有需要删除的节点组，直接跳过
    if [ ${#NODEGROUPS_TO_DELETE[@]} -eq 0 ]; then
        echo "✓ No existing nodegroups found, skipping deletion"
        return 0
    fi

    echo ""
    echo "⚠️  WARNING: The following nodegroup(s) will be deleted:"
    for NG_NAME in "${NODEGROUPS_TO_DELETE[@]}"; do
        echo "  - ${NG_NAME}"
    done
    echo ""
    echo "This will cause a service interruption of 5-8 minutes."

    # 支持非交互模式: AUTO_DELETE_NODEGROUP=yes
    if [ -n "${AUTO_DELETE_NODEGROUP}" ] && [[ "${AUTO_DELETE_NODEGROUP}" =~ ^[Yy] ]]; then
        echo "AUTO_DELETE_NODEGROUP is set, proceeding automatically..."
    else
        echo "Press Ctrl+C to cancel, or Enter to continue..."
        echo "For non-interactive mode, set AUTO_DELETE_NODEGROUP=yes"
        read
    fi

    # 删除找到的节点组
    for NG_NAME in "${NODEGROUPS_TO_DELETE[@]}"; do
        echo "Deleting nodegroup ${NG_NAME}..."
        eksctl delete nodegroup \
            --cluster="${CLUSTER_NAME}" \
            --region="${AWS_REGION}" \
            --name="${NG_NAME}" \
            --drain=false \
            --wait

        echo "✓ Nodegroup ${NG_NAME} deleted successfully"
    done

    echo "✓ All existing nodegroups deleted"

    # 清理可能残留的 ROLLBACK_COMPLETE / CREATE_FAILED CloudFormation stacks。
    # eksctl create nodegroup 会扫描 CFN stacks，发现同名 stack（即使已 rollback）
    # 就把该 nodegroup 列为"existing"并跳过创建，导致节点永远无法建出来。
    for NG_NAME in eks-utils eks-utils-arm64 eks-utils-x86; do
        CFN_STACK="eksctl-${CLUSTER_NAME}-nodegroup-${NG_NAME}"
        CFN_STATUS=$(aws cloudformation describe-stacks \
            --stack-name "${CFN_STACK}" --region "${AWS_REGION}" \
            --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "")
        case "${CFN_STATUS}" in
            ROLLBACK_COMPLETE|CREATE_FAILED|DELETE_FAILED)
                echo "Cleaning up leftover CloudFormation stack ${CFN_STACK} (${CFN_STATUS})..."
                aws cloudformation delete-stack \
                    --stack-name "${CFN_STACK}" --region "${AWS_REGION}"
                aws cloudformation wait stack-delete-complete \
                    --stack-name "${CFN_STACK}" --region "${AWS_REGION}" 2>/dev/null || true
                echo "✓ Stack ${CFN_STACK} deleted"
                ;;
            "") ;;  # stack 不存在，正常
            *) ;;   # ACTIVE 状态的 stack 不删
        esac
    done
}

# 创建节点组（引用Launch Template）
create_nodegroup_with_lt() {
    # 检查节点组是否已存在（幂等性）
    if aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name eks-utils \
        --region "${AWS_REGION}" &>/dev/null; then
        echo "✓ Nodegroup eks-utils already exists, skipping creation"
        return 0
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    # Build dynamic subnet configuration based on AZ_COUNT (supports 2-4 AZs)
    VPC_SUBNETS_YAML="      ${AZ_A}:
        id: \"${PRIVATE_SUBNET_A}\"
      ${AZ_B}:
        id: \"${PRIVATE_SUBNET_B}\""
    NG_SUBNETS_YAML="      - ${PRIVATE_SUBNET_A}
      - ${PRIVATE_SUBNET_B}"

    if [ "${AZ_COUNT}" -ge 3 ] && [ -n "${PRIVATE_SUBNET_C}" ]; then
        VPC_SUBNETS_YAML="${VPC_SUBNETS_YAML}
      ${AZ_C}:
        id: \"${PRIVATE_SUBNET_C}\""
        NG_SUBNETS_YAML="${NG_SUBNETS_YAML}
      - ${PRIVATE_SUBNET_C}"
    fi
    if [ "${AZ_COUNT}" -ge 4 ] && [ -n "${PRIVATE_SUBNET_D}" ]; then
        VPC_SUBNETS_YAML="${VPC_SUBNETS_YAML}
      ${AZ_D}:
        id: \"${PRIVATE_SUBNET_D}\""
        NG_SUBNETS_YAML="${NG_SUBNETS_YAML}
      - ${PRIVATE_SUBNET_D}"
    fi

    TEMP_CONFIG="/tmp/eksctl_ng_$$.yaml"
    cat > "${TEMP_CONFIG}" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"

vpc:
  id: "${VPC_ID}"
  subnets:
    private:
${VPC_SUBNETS_YAML}

managedNodeGroups:
  - name: eks-utils
    launchTemplate:
      id: ${LT_ID}
      version: "${LT_VERSION}"
    iam:
      instanceRoleARN: arn:aws:iam::${ACCOUNT_ID}:role/${NODE_ROLE_NAME}
    desiredCapacity: ${SYSTEM_NODE_DESIRED_CAPACITY}
    minSize: ${SYSTEM_NODE_MIN_SIZE}
    maxSize: ${SYSTEM_NODE_MAX_SIZE}
    privateNetworking: true
    subnets:
${NG_SUBNETS_YAML}
    labels:
      ${SYSTEM_NODE_LABEL_KEY}: "${SYSTEM_NODE_LABEL_VALUE}"
      arch: "${NODE_ARCH}"
      node-group-type: "system"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
EOF

    echo "Generated eksctl nodegroup config:"
    cat "${TEMP_CONFIG}"
    echo ""

    echo "Creating nodegroup..."
    eksctl create nodegroup -f "${TEMP_CONFIG}"

    rm -f "${TEMP_CONFIG}"
    echo "✓ Nodegroup created"
}

# 等待节点就绪
wait_for_nodes_ready() {
    echo "Waiting for nodes to be ready..."
    sleep 15

    RETRY_COUNT=0
    MAX_RETRIES=60

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        READY_NODES=$(kubectl get nodes -l ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE} --no-headers 2>/dev/null | grep -cw "Ready" || echo "0")
        READY_NODES=${READY_NODES//[^0-9]/}
        READY_NODES=${READY_NODES:-0}

        echo "Ready nodes: ${READY_NODES}/${SYSTEM_NODE_DESIRED_CAPACITY}"

        if [ "$READY_NODES" -ge "${SYSTEM_NODE_DESIRED_CAPACITY}" ]; then
            echo "✓ All nodes are ready!"
            return 0
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            echo "❌ ERROR: Timeout waiting for nodes"
            kubectl get nodes -l ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}
            exit 1
        fi

        sleep 10
    done
}

# 验证LVM配置
verify_lvm_configuration() {
    echo "Verifying LVM configuration on nodes..."

    local NODE_NAME=$(kubectl get nodes -l ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$NODE_NAME" ]; then
        echo "⚠ WARNING: Cannot verify LVM - no nodes found"
        return 0
    fi

    echo "Checking node: $NODE_NAME"

    # 验证节点状态
    local NODE_STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$NODE_STATUS" != "True" ]; then
        echo "❌ ERROR: Node $NODE_NAME is not Ready"
        return 1
    fi
    echo "✓ Node is Ready"

    # 验证实例类型
    local INSTANCE_TYPE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
    if [ "$INSTANCE_TYPE" != "$SYSTEM_NODE_INSTANCE_TYPE" ]; then
        echo "⚠ WARNING: Unexpected instance type: $INSTANCE_TYPE (expected: $SYSTEM_NODE_INSTANCE_TYPE)"
    else
        echo "✓ Instance type is correct: $INSTANCE_TYPE"
    fi

    echo "✓ LVM configuration verification complete"
    echo ""
    echo "To manually verify LVM on a node, run:"
    echo "  kubectl debug node/${NODE_NAME} -it --image=amazonlinux -- chroot /host bash -c 'vgs && lvs && df -h /var/lib/containerd'"
}

# ===================================================================
# 主流程
# ===================================================================

echo "=== Creating System Nodegroup with LVM Configuration ==="

# 步骤1：获取集群信息
echo ""
echo "Step 1: Gathering cluster information..."
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.endpoint' --output text)
CLUSTER_CA=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.certificateAuthority.data' --output text)
SERVICE_IPV4_CIDR=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text)

echo "Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "Service CIDR: ${SERVICE_IPV4_CIDR}"

# 步骤2：创建IAM Role和Instance Profile
echo ""
echo "Step 2: Creating IAM Role and Instance Profile..."
create_eks_node_iam_role

# Validate IAM role and instance profile were created successfully
validate_iam_role_exists "${NODE_ROLE_NAME}"
validate_instance_profile_exists "${INSTANCE_PROFILE_NAME}"

# 步骤2.5：确保 aws-auth configmap 包含节点 IAM role 映射
# 集群使用 API_AND_CONFIG_MAP 认证模式，节点 bootstrap（nodeadm）走 CONFIG_MAP
# 路径。eksctl 在 instanceRoleARN 模式下不会自动写入 aws-auth，必须手动确保。
echo ""
echo "Step 2.5: Ensuring aws-auth configmap has node IAM role mapping..."
NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${NODE_ROLE_NAME}"

# 读取当前 mapRoles
CURRENT_MAP=$(kubectl get configmap aws-auth -n kube-system \
    -o jsonpath='{.data.mapRoles}' 2>/dev/null || echo "")

if echo "${CURRENT_MAP}" | grep -q "${NODE_ROLE_ARN}"; then
    echo "✓ Node IAM role already present in aws-auth"
else
    echo "  Adding ${NODE_ROLE_ARN} to aws-auth..."

    # 构建新增条目
    NEW_ENTRY="- rolearn: ${NODE_ROLE_ARN}
  username: system:node:{{EC2PrivateDNSName}}
  groups:
    - system:bootstrappers
    - system:nodes"

    # 拼接（空或空数组时直接用新条目，否则追加）
    case "${CURRENT_MAP}" in
        ""|"[]"|"[ ]") NEW_MAP="${NEW_ENTRY}" ;;
        *)              NEW_MAP="${CURRENT_MAP}
${NEW_ENTRY}" ;;
    esac

    # 写入临时文件用 kubectl apply（避免多行字符串的 shell 转义问题）
    _AUTH_PATCH=$(mktemp /tmp/aws-auth-patch.XXXXXX.yaml)
    cat > "${_AUTH_PATCH}" <<AUTHEOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
$(echo "${NEW_MAP}" | sed 's/^/    /')
AUTHEOF
    kubectl apply -f "${_AUTH_PATCH}" 2>&1
    rm -f "${_AUTH_PATCH}"
    echo "✓ Node IAM role added to aws-auth"
fi

# 步骤3：获取最新的EKS optimized AMI
echo ""
echo "Step 3: Getting latest EKS optimized AMI..."

# 根据实例类型自动检测架构（查询 EC2 API，避免字符串启发式对 hpc7g 等
# family 的误判，以及未来新 family 的静默错配）。
AMI_ARCH=$(detect_instance_arch "${SYSTEM_NODE_INSTANCE_TYPE}") || exit 1
NODE_ARCH=$(instance_arch_to_go_arch "${AMI_ARCH}") || exit 1

echo "Instance Type: ${SYSTEM_NODE_INSTANCE_TYPE}"
echo "Detected Architecture: ${AMI_ARCH}"

# Use Amazon Linux 2023 with FSx Lustre support
AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/${AMI_ARCH}/standard/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" = "None" ]; then
    echo "❌ ERROR: Could not retrieve AMI ID from SSM parameter"
    echo "   Parameter: /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/${AMI_ARCH}/standard/recommended/image_id"
    exit 1
fi

echo "AMI ID: ${AMI_ID} (Amazon Linux 2023 ${AMI_ARCH} with FSx Lustre support)"

# Validate AMI exists and is available
validate_ami_exists "${AMI_ID}" "${AWS_REGION}"

# 步骤4：创建user-data（包含LVM setup和NodeConfig）
echo ""
echo "Step 4: Creating user-data with LVM configuration..."
create_lvm_userdata

# 步骤5：创建Launch Template
echo ""
echo "Step 5: Creating Launch Template..."
create_launch_template

# 步骤6：删除现有节点组（如果存在）
echo ""
echo "Step 6: Checking existing nodegroups..."
delete_existing_nodegroup

# 步骤7：创建新节点组
echo ""
echo "Step 7: Creating new nodegroup..."
create_nodegroup_with_lt

# 步骤8：等待节点就绪
echo ""
echo "Step 8: Waiting for nodes to be ready..."
wait_for_nodes_ready

# 步骤9：验证LVM配置
echo ""
echo "Step 9: Verifying LVM configuration..."
verify_lvm_configuration

# 完成
echo ""
echo "=== System Nodegroup with LVM Created Successfully ==="
echo ""
echo "Summary:"
echo "  • Launch Template: ${LT_NAME} (${LT_ID})"
echo "  • Instance Type: ${SYSTEM_NODE_INSTANCE_TYPE}"
echo "  • Root Volume: ${SYSTEM_NODE_ROOT_VOLUME_SIZE}GB (gp3)"
echo "  • Data Volume (LVM): ${SYSTEM_NODE_DATA_VOLUME_SIZE}GB (gp3, mounted at /var/lib/containerd)"
echo "  • Nodes: ${SYSTEM_NODE_DESIRED_CAPACITY} ready"
echo ""
kubectl get nodes -o wide
echo ""
echo "Next step: Continue with script 7 to install cluster addons"
echo "  ./scripts/legacy/7_install_eks_addon.sh"
echo ""
