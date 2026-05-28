#!/usr/bin/env bash
# safe-destroy.sh — tear down the EKS stack in the right order.
#
# Why this exists
# ---------------
# providers.tf wires `kubernetes` and `helm` providers to the cluster's
# endpoint via `aws eks get-token` exec auth. During `terraform destroy`
# Terraform deletes resources in reverse-dependency order, BUT the
# provider config itself is not part of the dependency graph: if the
# cluster is torn down (or kubelet fails) before all helm releases /
# K8s resources are removed, those resources fail to delete because
# their provider can no longer authenticate, and state gets stuck with
# orphans.
#
# This script forces the right order:
#   1. helm uninstall every release we manage (in reverse install order)
#   2. kubectl delete the ServiceAccounts we manage
#      (Pod Identity associations are removed by Terraform, but SAs
#       lingering with stale annotations confuse re-applies)
#   3. terraform destroy the rest
#
# Usage:
#   ./scripts/safe-destroy.sh [--auto-approve] [--var-file PATH]
#
# Env:
#   AWS_PROFILE / AWS_REGION  — passed through to aws/helm/kubectl
#   CLUSTER_NAME              — auto-detected from terraform output if unset
#
# Exit codes:
#   0 — clean teardown
#   1 — terraform destroy failed (manual intervention required)
#   2 — pre-destroy cleanup failed but destroy continued
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "${SCRIPT_DIR}")"

AUTO_APPROVE=""
VAR_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE="-auto-approve"; shift ;;
    --var-file)     VAR_FILE="-var-file=$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

cd "${TF_DIR}"

# Resolve cluster name.
CLUSTER_NAME="${CLUSTER_NAME:-$(terraform output -raw cluster_name 2>/dev/null || true)}"
if [ -z "${CLUSTER_NAME}" ]; then
  echo "WARN: cannot resolve cluster_name from terraform output; skipping helm/kubectl cleanup."
  echo "      Run 'terraform destroy' directly if the state is already broken."
else
  REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
  echo "==> Resolving kubeconfig for ${CLUSTER_NAME} in ${REGION}..."
  if aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" --alias "${CLUSTER_NAME}" >/dev/null 2>&1; then
    KCTX="--context=${CLUSTER_NAME}"
    NS="kube-system"

    echo "==> Helm uninstall (reverse install order)..."
    # karpenter-pools depends on karpenter; karpenter depends on cluster.
    # Other releases are independent but share the same cluster.
    # Added 2026-05-22: dcgm-exporter, node-problem-detector (standard mode);
    # gpu-operator lives in its own namespace and is handled below.
    for release in karpenter-pools karpenter nvidia-device-plugin dcgm-exporter node-problem-detector aws-load-balancer-controller cluster-autoscaler aws-fsx-csi-driver; do
      if helm $KCTX list -n "${NS}" --short 2>/dev/null | grep -qx "${release}"; then
        echo "  - uninstalling ${release}"
        helm $KCTX uninstall "${release}" -n "${NS}" --wait --timeout 5m \
          || echo "    WARN: helm uninstall ${release} failed; continuing"
      else
        echo "  - ${release}: not installed, skip"
      fi
    done

    # Operator-mode artifacts: helm release lives in its own ns/gpu-operator,
    # and the namespace itself must be removed for a clean state.
    if helm $KCTX list -n gpu-operator --short 2>/dev/null | grep -qx "gpu-operator"; then
      echo "  - uninstalling gpu-operator (ns=gpu-operator)"
      helm $KCTX uninstall gpu-operator -n gpu-operator --wait --timeout 10m \
        || echo "    WARN: helm uninstall gpu-operator failed; continuing"
    fi
    kubectl $KCTX delete namespace gpu-operator --ignore-not-found --timeout=120s 2>/dev/null \
      || echo "  WARN: failed to delete ns/gpu-operator; continuing"

    # Standalone health-check resources (kubectl-managed in bash path,
    # terraform-managed in tf path — but safe-destroy runs before the
    # helm/k8s API is torn down, so pre-clean either way).
    kubectl $KCTX delete daemonset gpu-health-check -n "${NS}" --ignore-not-found --timeout=60s 2>/dev/null \
      || echo "  WARN: failed to delete ds/gpu-health-check; continuing"
    kubectl $KCTX delete clusterrolebinding gpu-health-check --ignore-not-found --timeout=30s 2>/dev/null \
      || echo "  WARN: failed to delete clusterrolebinding/gpu-health-check; continuing"
    kubectl $KCTX delete clusterrole gpu-health-check --ignore-not-found --timeout=30s 2>/dev/null \
      || echo "  WARN: failed to delete clusterrole/gpu-health-check; continuing"
    kubectl $KCTX delete serviceaccount gpu-health-check -n "${NS}" --ignore-not-found --timeout=30s 2>/dev/null \
      || echo "  WARN: failed to delete sa/gpu-health-check; continuing"

    echo "==> Deleting ServiceAccounts that Terraform won't clean by itself..."
    for sa in karpenter cluster-autoscaler aws-load-balancer-controller fsx-csi-controller-sa; do
      kubectl $KCTX delete serviceaccount "${sa}" -n "${NS}" --ignore-not-found --timeout=30s 2>/dev/null \
        || echo "  WARN: failed to delete sa/${sa}; continuing"
    done

    # Force delete any lingering kubernetes_manifest objects (NodePool etc.)
    # that bedag/raw chart left behind.
    echo "==> Cleaning stray Karpenter custom resources..."
    kubectl $KCTX delete nodepool --all --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl $KCTX delete ec2nodeclass --all --ignore-not-found --timeout=30s 2>/dev/null || true
  else
    echo "WARN: aws eks update-kubeconfig failed; skipping helm/kubectl cleanup."
    echo "      The cluster API may already be down. Continuing to terraform destroy."
  fi
fi

echo ""
echo "==> Running terraform destroy..."
terraform destroy ${AUTO_APPROVE} ${VAR_FILE} -input=false
RC=$?

if [ $RC -ne 0 ]; then
  echo ""
  echo "==> terraform destroy failed (rc=$RC). Common follow-ups:"
  echo "    1. Check stuck resources: terraform state list | grep -E 'helm_release|kubernetes_'"
  echo "    2. Force-remove from state if K8s API is dead:"
  echo "         terraform state rm <addr>"
  echo "    3. Re-run this script."
  exit 1
fi

echo ""
echo "==> Clean teardown complete."
echo "    Don't forget the bootstrap-vpc/ stack:"
echo "      cd bootstrap-vpc && terraform destroy"
