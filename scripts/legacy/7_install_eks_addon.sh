#!/bin/bash

set -e
set -o pipefail
export AWS_PAGER=""

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "=== EKS Addons Installation (Cluster Autoscaler, Load Balancer Controller) ==="

# 1. Load environment variables
source "${SCRIPT_DIR}/../0_setup_env.sh"

# 1.1 Set KUBECONFIG environment variable
export KUBECONFIG="${HOME:-/root}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.2. Import Pod Identity helper functions
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 1.3. Check required dependencies
echo "Checking required dependencies..."
MISSING_DEPS=()

command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v aws >/dev/null 2>&1 || MISSING_DEPS+=("aws cli")
command -v helm >/dev/null 2>&1 || MISSING_DEPS+=("helm")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")

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

# 2. Verify cluster exists and update kubeconfig
echo "Verifying EKS cluster exists and updating kubeconfig..."
validate_eks_cluster_exists "${CLUSTER_NAME}" "${AWS_REGION}"

# Verify kubectl context
verify_kubectl_context
echo ""
echo "Note: Security group configuration for bastion access should have been"
echo "      completed in script 6_create_system_nodegroup.sh"
echo ""

# 3. Verify cluster status
echo "Checking cluster status..."
echo "Note: If cluster uses private-only access, kubectl may timeout. This is expected."
timeout 10 kubectl get nodes || echo "Warning: kubectl timeout - using AWS CLI to verify cluster"
timeout 10 kubectl get pods -A || aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.status'

# 3.1. Wait for Pod Identity Agent to be ready
echo ""
echo "Step 3.1: Waiting for Pod Identity Agent..."
wait_for_pod_identity_agent

# 3.2. Ensure CoreDNS addon exists (fallback if not created by eksctl)
echo ""
echo "Step 3.2: Checking CoreDNS addon..."
if ! aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name coredns --region "${AWS_REGION}" &>/dev/null; then
    echo "coredns addon not found, creating with custom configuration..."
    COREDNS_CONFIG=$(cat <<'EOFCONFIG'
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
EOFCONFIG
)
    # Substitute environment variables
    COREDNS_CONFIG=$(echo "$COREDNS_CONFIG" | sed \
        -e "s/\${SYSTEM_NODE_LABEL_KEY}/${SYSTEM_NODE_LABEL_KEY}/g" \
        -e "s/\${SYSTEM_NODE_LABEL_VALUE}/${SYSTEM_NODE_LABEL_VALUE}/g")

    # Omit --addon-version so AWS selects the default compatible version for K8S_VERSION.
    aws eks create-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --addon-name coredns \
        --configuration-values "$COREDNS_CONFIG" \
        --region "${AWS_REGION}"
    echo "✓ coredns addon created"
fi
echo "Waiting for CoreDNS addon..."
wait_for_eks_addon "coredns"
echo "✓ CoreDNS addon ready"

# 3.3. Ensure Metrics Server addon exists (fallback if not created by eksctl)
echo ""
echo "Step 3.3: Checking Metrics Server addon..."
if ! aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name metrics-server --region "${AWS_REGION}" &>/dev/null; then
    echo "metrics-server addon not found, creating with custom configuration..."
    METRICS_SERVER_CONFIG=$(cat <<'EOFCONFIG'
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
EOFCONFIG
)
    # Substitute environment variables
    METRICS_SERVER_CONFIG=$(echo "$METRICS_SERVER_CONFIG" | sed \
        -e "s/\${SYSTEM_NODE_LABEL_KEY}/${SYSTEM_NODE_LABEL_KEY}/g" \
        -e "s/\${SYSTEM_NODE_LABEL_VALUE}/${SYSTEM_NODE_LABEL_VALUE}/g")

    # Omit --addon-version so AWS selects the default compatible version for K8S_VERSION.
    aws eks create-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --addon-name metrics-server \
        --configuration-values "$METRICS_SERVER_CONFIG" \
        --region "${AWS_REGION}"
    echo "✓ metrics-server addon created"
fi
echo "Waiting for Metrics Server addon..."
wait_for_eks_addon "metrics-server"
echo "✓ Metrics Server addon ready"

# 4. Setup Cluster Autoscaler with Pod Identity
echo ""
echo "Step 4: Setting up Cluster Autoscaler with Pod Identity..."
setup_cluster_autoscaler_pod_identity

# 4.1 Deploy Cluster Autoscaler RBAC
echo "Deploying Cluster Autoscaler RBAC..."
kubectl apply -f "${SCRIPT_DIR}/manifests/addons/cluster-autoscaler-rbac.yaml"

# 4.2 Deploy Cluster Autoscaler Deployment
echo "Deploying Cluster Autoscaler..."
sed -e "s|\${CLUSTER_NAME}|$CLUSTER_NAME|g" \
    -e "s|\${AWS_REGION}|$AWS_REGION|g" \
    -e "s|\${CLUSTER_AUTOSCALER_VERSION}|$CLUSTER_AUTOSCALER_VERSION|g" \
    -e "s|\${SYSTEM_NODE_LABEL_KEY}|$SYSTEM_NODE_LABEL_KEY|g" \
    -e "s|\${SYSTEM_NODE_LABEL_VALUE}|$SYSTEM_NODE_LABEL_VALUE|g" \
    "${SCRIPT_DIR}/manifests/addons/cluster-autoscaler.yaml" | kubectl apply -f -

# 4.3 Verify Cluster Autoscaler
echo "Checking Cluster Autoscaler status..."
kubectl get deployment cluster-autoscaler -n kube-system

echo "Waiting for Cluster Autoscaler to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/cluster-autoscaler -n kube-system

kubectl logs -n kube-system -l app=cluster-autoscaler --tail=10

# 5. Setup AWS Load Balancer Controller with Pod Identity
echo ""
echo "Step 5: Setting up AWS Load Balancer Controller with Pod Identity..."
setup_alb_controller_pod_identity

# 5.1 Deploy Load Balancer Controller
echo "Deploying Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=${CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set vpcId=${VPC_ID} \
    --set region=${AWS_REGION} \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set "nodeSelector.${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}" \
    --set replicaCount=2 \
    --set podDisruptionBudget.minAvailable=1 \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.memory=256Mi \
    --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchLabels.app\.kubernetes\.io/name=aws-load-balancer-controller" \
    --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey=kubernetes.io/hostname" \
    --set image.tag="${ALB_CONTROLLER_VERSION}" \
    --version "${ALB_CONTROLLER_CHART_VERSION}"

# 5.2 Verify Load Balancer Controller
echo "Testing AWS Load Balancer Controller..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=10

# 6. Verify Metrics Server functionality
echo ""
echo "Step 6: Verifying Metrics Server functionality..."
sleep 5
if kubectl top nodes &>/dev/null; then
    echo "✓ Metrics Server is working correctly"
    kubectl top nodes
else
    echo "Note: Metrics Server may need more time to collect metrics (this is normal)"
    echo "You can verify later with: kubectl top nodes"
fi

# 7. Final verification
echo ""
echo "Step 7: Verifying all Pod Identity Associations..."
list_pod_identity_associations

echo ""
echo "=== EKS Addons Installation Complete ==="
echo "✓ CoreDNS addon ready (configured in cluster creation)"
echo "✓ Metrics Server addon ready (configured in cluster creation)"
echo "✓ Cluster Autoscaler installed and configured"
echo "✓ AWS Load Balancer Controller installed and configured"
echo "✓ All components use Pod Identity for AWS authentication"
echo ""
echo "Next steps:"
echo "  1. Check nodes: kubectl get nodes --show-labels"
echo "  2. Check all pods: kubectl get pods -A"
echo "  3. Verify metrics: kubectl top nodes"
echo "  4. Deploy test app: kubectl apply -f examples/autoscaler.yaml"
echo "  5. Install CSI drivers: ./scripts/legacy/option_install_csi_drivers.sh (EBS, EFS, FSx, S3)"
echo "  6. Optional: Install Karpenter with ./scripts/legacy/option_install_karpenter.sh"
echo ""