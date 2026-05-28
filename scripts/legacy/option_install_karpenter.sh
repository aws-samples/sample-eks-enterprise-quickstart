#!/bin/bash

set -e
set -o pipefail
export AWS_PAGER=""

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "=== Installing Karpenter on EKS Cluster ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/../0_setup_env.sh"

# 1.1 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME:-/root}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.5. 导入 Pod Identity helper 函数
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 2. 验证集群存在并更新 kubeconfig
echo "Step 1: Checking if cluster exists and updating kubeconfig..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "❌ ERROR: Cluster ${CLUSTER_NAME} does not exist"
    exit 1
fi

# 验证 kubectl context（使用统一函数）
verify_kubectl_context

# 2.5. 验证kubectl访问权限
echo ""
echo "Step 1.5: Verifying kubectl access to cluster..."
if ! kubectl get nodes &>/dev/null; then
    echo "❌ ERROR: Cannot access cluster with kubectl"
    echo ""
    echo "This usually means:"
    echo "  1. You don't have permission to access the cluster"
    echo "  2. Security groups are not configured correctly"
    echo "  3. You're not running from within the VPC"
    echo ""
    echo "If running from a bastion host, ensure:"
    echo "  - Bastion security group can access EKS API (port 443)"
    echo "  - Bastion IAM role has EKS cluster access"
    echo ""
    echo "To configure access, run: ./scripts/create_bastion.sh"
    exit 1
fi
echo "✓ kubectl access verified"

# 3. 获取集群信息
echo ""
echo "Step 2: Getting cluster information..."
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.endpoint" --output text)
OIDC_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo "  Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "  OIDC Endpoint: ${OIDC_ENDPOINT}"
echo "  Account ID: ${ACCOUNT_ID}"

# 4. Karpenter 版本（来自 0_setup_env.sh，可通过 .env 覆盖）
echo ""
echo "Step 3: Installing Karpenter version ${KARPENTER_VERSION}..."

# 5. 创建 Karpenter Node IAM Role
echo ""
echo "Step 4: Creating Karpenter Node IAM Role..."

KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"

# 检查角色是否已存在
if aws iam get-role --role-name "${KARPENTER_NODE_ROLE}" &>/dev/null; then
    echo "  Role ${KARPENTER_NODE_ROLE} already exists, skipping creation"
else
    echo "  Creating IAM role ${KARPENTER_NODE_ROLE}..."

    # 创建信任策略（使用 mktemp 避免临时文件冲突）
    KARPENTER_NODE_TRUST_FILE=$(mktemp /tmp/karpenter-node-trust-policy.XXXXXX.json)

    cat > "${KARPENTER_NODE_TRUST_FILE}" <<EOF
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
        --role-name "${KARPENTER_NODE_ROLE}" \
        --assume-role-policy-document "file://${KARPENTER_NODE_TRUST_FILE}" \
        --tags \
            Key=ManagedBy,Value=karpenter \
            Key=Cluster,Value="${CLUSTER_NAME}" \
            Key=business,Value=middleware \
            Key=resource,Value=eks

    rm -f "${KARPENTER_NODE_TRUST_FILE}"

    # 附加必需的策略
    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

    echo "  ✓ IAM role ${KARPENTER_NODE_ROLE} created successfully"
fi

# 创建 Instance Profile（如果不存在）
echo "  Creating Instance Profile for ${KARPENTER_NODE_ROLE}..."
if ! aws iam get-instance-profile --instance-profile-name "${KARPENTER_NODE_ROLE}" &>/dev/null; then
    aws iam create-instance-profile \
        --instance-profile-name "${KARPENTER_NODE_ROLE}" \
        --tags \
            Key=ManagedBy,Value=karpenter \
            Key=Cluster,Value="${CLUSTER_NAME}" \
            Key=business,Value=middleware \
            Key=resource,Value=eks

    aws iam add-role-to-instance-profile \
        --instance-profile-name "${KARPENTER_NODE_ROLE}" \
        --role-name "${KARPENTER_NODE_ROLE}"

    echo "  ✓ Instance Profile ${KARPENTER_NODE_ROLE} created successfully"
else
    echo "  Instance Profile ${KARPENTER_NODE_ROLE} already exists"
fi

# 添加 KarpenterNodeRole 到 EKS 访问配置（允许节点加入集群）
echo "  Adding ${KARPENTER_NODE_ROLE} to EKS access entries..."
KARPENTER_NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE}"
if aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" --principal-arn "${KARPENTER_NODE_ROLE_ARN}" &>/dev/null; then
    echo "  EKS access entry for ${KARPENTER_NODE_ROLE} already exists"
else
    # EKS access entry creation can race with IAM role propagation when
    # the role was just created a few seconds ago. EKS's API returns
    # "invalid principalArn" in that window. Retry briefly — the role
    # normally becomes visible to EKS within 10-30 seconds.
    for attempt in 1 2 3 4 5 6; do
        if aws eks create-access-entry \
            --cluster-name "${CLUSTER_NAME}" \
            --principal-arn "${KARPENTER_NODE_ROLE_ARN}" \
            --type EC2_LINUX 2>/tmp/eks-access-entry.err; then
            echo "  ✓ EKS access entry created for ${KARPENTER_NODE_ROLE}"
            rm -f /tmp/eks-access-entry.err
            break
        fi
        if grep -q "invalid principalArn\|invalid principal" /tmp/eks-access-entry.err 2>/dev/null; then
            echo "  IAM role not yet visible to EKS, retrying in 10s (attempt ${attempt}/6)..."
            sleep 10
        else
            cat /tmp/eks-access-entry.err >&2
            rm -f /tmp/eks-access-entry.err
            echo "  ✗ EKS access entry creation failed with non-retryable error" >&2
            exit 1
        fi
        if [ "${attempt}" -eq 6 ]; then
            echo "  ✗ Timed out waiting for IAM role to become visible to EKS" >&2
            cat /tmp/eks-access-entry.err >&2 2>/dev/null
            rm -f /tmp/eks-access-entry.err
            exit 1
        fi
    done
fi

# 6. 创建 Karpenter Controller IAM Policy
echo ""
echo "Step 5: Creating Karpenter Controller IAM Policy..."

KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"

# 生成策略文档（使用 mktemp 避免临时文件冲突）
KARPENTER_CONTROLLER_POLICY_FILE=$(mktemp /tmp/karpenter-controller-policy.XXXXXX.json)

# This policy follows the least-privilege structure of the upstream
# Karpenter v1 CloudFormation template
# (https://karpenter.sh/docs/reference/cloudformation/). Each write
# action is constrained to resources that Karpenter itself created
# (identified by the cluster-owner and per-nodepool tags that Karpenter
# attaches automatically: `kubernetes.io/cluster/<cluster>=owned`,
# `karpenter.sh/nodepool=<name>`, `karpenter.k8s.aws/ec2nodeclass=<name>`).
#
# Effect of the constraints:
#   - The controller cannot terminate instances / delete LaunchTemplates /
#     delete or modify InstanceProfiles outside this cluster.
#   - CreateTags can only ride along with a RunInstances/CreateFleet/
#     CreateLaunchTemplate call in the same request (ec2:CreateAction)
#     or target instances already tagged as owned by this cluster.
#   - Read-only describe calls are scoped to the cluster's region.
cat > "${KARPENTER_CONTROLLER_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowScopedEC2InstanceAccessActions",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet"
      ],
      "Resource": [
        "arn:aws:ec2:${AWS_REGION}::image/*",
        "arn:aws:ec2:${AWS_REGION}::snapshot/*",
        "arn:aws:ec2:${AWS_REGION}:*:security-group/*",
        "arn:aws:ec2:${AWS_REGION}:*:subnet/*",
        "arn:aws:ec2:${AWS_REGION}:*:capacity-reservation/*"
      ]
    },
    {
      "Sid": "AllowScopedEC2LaunchTemplateAccessActions",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet"
      ],
      "Resource": "arn:aws:ec2:${AWS_REGION}:*:launch-template/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedEC2InstanceActionsWithTags",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate"
      ],
      "Resource": [
        "arn:aws:ec2:${AWS_REGION}:*:fleet/*",
        "arn:aws:ec2:${AWS_REGION}:*:instance/*",
        "arn:aws:ec2:${AWS_REGION}:*:volume/*",
        "arn:aws:ec2:${AWS_REGION}:*:network-interface/*",
        "arn:aws:ec2:${AWS_REGION}:*:launch-template/*",
        "arn:aws:ec2:${AWS_REGION}:*:spot-instances-request/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:RequestTag/eks:eks-cluster-name": "${CLUSTER_NAME}"
        },
        "StringLike": {
          "aws:RequestTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedResourceCreationTagging",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": [
        "arn:aws:ec2:${AWS_REGION}:*:fleet/*",
        "arn:aws:ec2:${AWS_REGION}:*:instance/*",
        "arn:aws:ec2:${AWS_REGION}:*:volume/*",
        "arn:aws:ec2:${AWS_REGION}:*:network-interface/*",
        "arn:aws:ec2:${AWS_REGION}:*:launch-template/*",
        "arn:aws:ec2:${AWS_REGION}:*:spot-instances-request/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:RequestTag/eks:eks-cluster-name": "${CLUSTER_NAME}",
          "ec2:CreateAction": [
            "RunInstances",
            "CreateFleet",
            "CreateLaunchTemplate"
          ]
        },
        "StringLike": {
          "aws:RequestTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedResourceTagging",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:${AWS_REGION}:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        },
        "ForAllValues:StringEquals": {
          "aws:TagKeys": [
            "karpenter.sh/nodeclaim",
            "Name"
          ]
        }
      }
    },
    {
      "Sid": "AllowScopedDeletion",
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances",
        "ec2:DeleteLaunchTemplate",
        "ec2:DeleteLaunchTemplateVersions"
      ],
      "Resource": [
        "arn:aws:ec2:${AWS_REGION}:*:instance/*",
        "arn:aws:ec2:${AWS_REGION}:*:launch-template/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowRegionalReadActions",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "${AWS_REGION}"
        }
      }
    },
    {
      "Sid": "AllowSSMReadActions",
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:${AWS_REGION}::parameter/aws/service/eks/*"
    },
    {
      "Sid": "AllowPricingReadActions",
      "Effect": "Allow",
      "Action": "pricing:GetProducts",
      "Resource": "*"
    },
    {
      "Sid": "AllowInterruptionQueueActions",
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:SetQueueAttributes",
        "sqs:TagQueue"
      ],
      "Resource": "arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:Karpenter-${CLUSTER_NAME}-*"
    },
    {
      "Sid": "AllowAPIServerEndpointDiscovery",
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
    },
    {
      "Sid": "AllowEventBridgeRuleActions",
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:PutTargets",
        "events:DeleteRule",
        "events:RemoveTargets",
        "events:DescribeRule"
      ],
      "Resource": "arn:aws:events:${AWS_REGION}:${ACCOUNT_ID}:rule/KarpenterInterruptionQueue-${CLUSTER_NAME}"
    },
    {
      "Sid": "AllowPassingInstanceRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE}",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "AllowScopedInstanceProfileCreationActions",
      "Effect": "Allow",
      "Action": "iam:CreateInstanceProfile",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:instance-profile/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:RequestTag/eks:eks-cluster-name": "${CLUSTER_NAME}",
          "aws:RequestTag/topology.kubernetes.io/region": "${AWS_REGION}"
        },
        "StringLike": {
          "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedInstanceProfileTagActions",
      "Effect": "Allow",
      "Action": "iam:TagInstanceProfile",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:instance-profile/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:ResourceTag/topology.kubernetes.io/region": "${AWS_REGION}"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedInstanceProfileActions",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:instance-profile/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:ResourceTag/topology.kubernetes.io/region": "${AWS_REGION}"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      }
    },
    {
      "Sid": "AllowInstanceProfileReadActions",
      "Effect": "Allow",
      "Action": [
        "iam:GetInstanceProfile",
        "iam:ListInstanceProfiles",
        "iam:ListInstanceProfileTags"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:instance-profile/*"
    }
  ]
}
EOF

# 检查策略是否已存在
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" &>/dev/null; then
    echo "  Policy ${KARPENTER_CONTROLLER_POLICY} already exists, updating to latest version..."

    # 删除非默认的旧版本（AWS 限制最多 5 个版本）
    POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}"
    OLD_VERSIONS=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
    for VERSION in $OLD_VERSIONS; do
        echo "  Deleting old policy version: ${VERSION}"
        aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${VERSION}" 2>/dev/null || true
    done

    # 创建新版本并设为默认
    aws iam create-policy-version \
        --policy-arn "${POLICY_ARN}" \
        --policy-document "file://${KARPENTER_CONTROLLER_POLICY_FILE}" \
        --set-as-default

    echo "  ✓ IAM policy updated to new version"
else
    echo "  Creating IAM policy ${KARPENTER_CONTROLLER_POLICY}..."

    aws iam create-policy \
        --policy-name "${KARPENTER_CONTROLLER_POLICY}" \
        --policy-document "file://${KARPENTER_CONTROLLER_POLICY_FILE}" \
        --tags Key=ManagedBy,Value=karpenter Key=Cluster,Value="${CLUSTER_NAME}"

    echo "  ✓ IAM policy ${KARPENTER_CONTROLLER_POLICY} created successfully"
fi

rm -f "${KARPENTER_CONTROLLER_POLICY_FILE}"

# 7. 创建 Karpenter Controller IAM Role
echo ""
echo "Step 6: Creating Karpenter Controller IAM Role..."

KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"

# 检查角色是否已存在
if aws iam get-role --role-name "${KARPENTER_CONTROLLER_ROLE}" &>/dev/null; then
    echo "  Role ${KARPENTER_CONTROLLER_ROLE} already exists, skipping creation"
else
    echo "  Creating IAM role ${KARPENTER_CONTROLLER_ROLE}..."

    # 创建信任策略 (Pod Identity) - 使用 mktemp 避免临时文件冲突
    KARPENTER_CONTROLLER_TRUST_FILE=$(mktemp /tmp/karpenter-controller-trust-policy.XXXXXX.json)

    cat > "${KARPENTER_CONTROLLER_TRUST_FILE}" <<EOF
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

    aws iam create-role \
        --role-name "${KARPENTER_CONTROLLER_ROLE}" \
        --assume-role-policy-document "file://${KARPENTER_CONTROLLER_TRUST_FILE}" \
        --tags Key=ManagedBy,Value=karpenter Key=Cluster,Value="${CLUSTER_NAME}"

    rm -f "${KARPENTER_CONTROLLER_TRUST_FILE}"

    # 附加 Karpenter Controller Policy
    aws iam attach-role-policy \
        --role-name "${KARPENTER_CONTROLLER_ROLE}" \
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}"

    echo "  ✓ IAM role ${KARPENTER_CONTROLLER_ROLE} created successfully"
fi

# 8. 使用 Pod Identity 创建 Karpenter Service Account 关联
echo ""
echo "Step 7: Setting up Karpenter with Pod Identity..."

KARPENTER_NAMESPACE="kube-system"
KARPENTER_SA="karpenter"

# 创建 Service Account（如果不存在）
if ! kubectl get sa "${KARPENTER_SA}" -n "${KARPENTER_NAMESPACE}" &>/dev/null; then
    kubectl create serviceaccount "${KARPENTER_SA}" -n "${KARPENTER_NAMESPACE}"
    echo "  ✓ Service Account ${KARPENTER_SA} created"
else
    echo "  Service Account ${KARPENTER_SA} already exists"
fi

# 创建 Pod Identity Association
echo "  Creating Pod Identity Association for Karpenter..."

# 检查是否已存在
EXISTING_ASSOCIATION=$(aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${KARPENTER_NAMESPACE}" \
    --region "${AWS_REGION}" \
    --query "associations[?serviceAccount=='${KARPENTER_SA}'].associationId" \
    --output text 2>/dev/null)

if [ -z "$EXISTING_ASSOCIATION" ]; then
    aws eks create-pod-identity-association \
        --cluster-name "${CLUSTER_NAME}" \
        --namespace "${KARPENTER_NAMESPACE}" \
        --service-account "${KARPENTER_SA}" \
        --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_CONTROLLER_ROLE}" \
        --region "${AWS_REGION}"
    echo "  ✓ Pod Identity Association created successfully"
else
    echo "  Pod Identity Association already exists (ID: ${EXISTING_ASSOCIATION})"
fi

# 9. 为子网和安全组打标签
echo ""
echo "Step 8: Tagging subnets and security groups for Karpenter discovery..."

# 获取集群的安全组
CLUSTER_SG=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

# 标记子网 (supports 2-4 AZs using PRIVATE_SUBNETS from 0_setup_env.sh)
IFS=',' read -ra SUBNET_ARRAY <<< "${PRIVATE_SUBNETS}"
for SUBNET in "${SUBNET_ARRAY[@]}"; do
    aws ec2 create-tags \
        --resources "${SUBNET}" \
        --tags Key=karpenter.sh/discovery,Value="${CLUSTER_NAME}" \
        --region "${AWS_REGION}"
    echo "  ✓ Tagged subnet ${SUBNET}"
done

# 标记安全组
aws ec2 create-tags \
    --resources "${CLUSTER_SG}" \
    --tags Key=karpenter.sh/discovery,Value="${CLUSTER_NAME}" \
    --region "${AWS_REGION}"
echo "  ✓ Tagged security group ${CLUSTER_SG}"

# 10. 安装 Karpenter Helm Chart
echo ""
echo "Step 9: Installing Karpenter Helm Chart..."

# 注意: Karpenter v1.x 使用 OCI registry，不需要添加 helm repo
# 安装 Karpenter - 确保只运行在系统节点组
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --namespace "${KARPENTER_NAMESPACE}" \
    --version "${KARPENTER_VERSION}" \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
    --set "serviceAccount.create=false" \
    --set "serviceAccount.name=${KARPENTER_SA}" \
    --set "replicas=2" \
    --set "nodeSelector.${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}" \
    --set "tolerations[0].key=CriticalAddonsOnly" \
    --set "tolerations[0].operator=Exists" \
    --set "tolerations[1].key=node.kubernetes.io/not-ready" \
    --set "tolerations[1].operator=Exists" \
    --set "tolerations[1].effect=NoExecute" \
    --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=karpenter.sh/nodepool" \
    --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=DoesNotExist" \
    --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchLabels.app\.kubernetes\.io/name=karpenter" \
    --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey=kubernetes.io/hostname" \
    --set "podDisruptionBudget.minAvailable=1" \
    --timeout 10m \
    --wait

# Note: Removed settings.interruptionQueue as SQS queue is not created by default
# To enable interruption handling, create an SQS queue and EventBridge rules manually

echo "  ✓ Karpenter Helm Chart installed successfully"

# 11. 等待 Karpenter Pods 就绪
echo ""
echo "Step 10: Waiting for Karpenter pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=karpenter -n "${KARPENTER_NAMESPACE}" --timeout=300s

# 12. 部署 EC2NodeClass 和 NodePool
echo ""
echo "Step 11: Deploying EC2NodeClass and NodePool..."

export CLUSTER_NAME
export AWS_REGION

# SSH public key for Karpenter nodes (optional)
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    echo "  SSH public key will be injected into Karpenter nodes"
fi

# 部署 Graviton NodePool（r/c/m Graviton family，4-16 vCPU；详见 manifest 注释）
if [ "${DEPLOY_GRAVITON_NODEPOOL:-true}" = "true" ]; then
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        -e "s|\${SSH_PUBLIC_KEY}|${SSH_PUBLIC_KEY:-}|g" \
        "${PROJECT_ROOT}/terraform/assets/karpenter/ec2nodeclass-graviton.yaml" | kubectl apply -f -
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        "${PROJECT_ROOT}/terraform/assets/karpenter/nodepool-graviton.yaml" | kubectl apply -f -
    echo "  ✓ Graviton EC2NodeClass and NodePool deployed (arm64, r/c/m 4-16 vCPU)"
fi

# 可选：部署 x86 NodePool（r/c/m Intel family，4-16 vCPU；详见 manifest 注释）
if [ "${DEPLOY_X86_NODEPOOL:-true}" = "true" ]; then
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        -e "s|\${SSH_PUBLIC_KEY}|${SSH_PUBLIC_KEY:-}|g" \
        "${PROJECT_ROOT}/terraform/assets/karpenter/ec2nodeclass-x86.yaml" | kubectl apply -f -
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        "${PROJECT_ROOT}/terraform/assets/karpenter/nodepool-x86.yaml" | kubectl apply -f -
    echo "  ✓ x86 EC2NodeClass and NodePool deployed (amd64, r/c/m 4-16 vCPU)"
fi

# 13. 验证安装
echo ""
echo "Step 12: Verifying Karpenter installation..."

echo ""
echo "Karpenter Pods:"
kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter

echo ""
echo "EC2NodeClasses:"
kubectl get ec2nodeclass

echo ""
echo "NodePools:"
kubectl get nodepool

# 14. 显示最终状态
echo ""
echo "=== Karpenter Installation Complete ==="
echo ""
echo "Karpenter Information:"
echo "  Version: ${KARPENTER_VERSION}"
echo "  Namespace: ${KARPENTER_NAMESPACE}"
echo "  Service Account: ${KARPENTER_SA}"
echo "  Controller IAM Role: ${KARPENTER_CONTROLLER_ROLE}"
echo "  Node IAM Role: ${KARPENTER_NODE_ROLE}"
echo ""
echo "Installed NodePools:"
if [ "${DEPLOY_GRAVITON_NODEPOOL:-true}" = "true" ]; then
    echo "  - graviton: arm64, r/c/m Graviton family, 4-16 vCPU, on-demand"
fi
if [ "${DEPLOY_X86_NODEPOOL:-true}" = "true" ]; then
    echo "  - x86:      amd64, r/c/m Intel family, 4-16 vCPU, on-demand"
fi
echo ""
echo "Features:"
echo "  - Additional 100GB data disk attached (manual LVM setup required)"
echo "  - EBS volume encryption enabled"
echo "  - Pod Identity authentication"
echo "  - Architecture-specific node pools (ARM64 & x86_64)"
echo ""
echo "Next steps:"
echo "  1. Check Karpenter logs: kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter"
echo "  2. Test provisioning: kubectl scale deployment inflate --replicas=10"
echo "  3. Monitor nodes: kubectl get nodes -w"
echo "  4. Customize NodePools: edit terraform/assets/karpenter/*.yaml and reapply"
echo ""
