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
#   1. helm uninstall karpenter-pools, then delete any remaining Karpenter
#      NodePools / EC2NodeClasses and wait until they and their NodeClaims
#      are gone — while the Karpenter controller (and its ServiceAccount /
#      Pod Identity) is still running to clear the
#      karpenter.k8s.aws/termination finalizers
#   2. helm uninstall karpenter, then every other release we manage
#      (reverse install order)
#   3. kubectl delete the ServiceAccounts we manage — each only after its
#      release is confirmed gone
#      (Pod Identity associations are removed by Terraform, but SAs
#       lingering with stale annotations confuse re-applies)
#   4. terraform destroy the rest
#
# If helm or kubectl cannot reach the cluster, the whole cleanup is skipped
# (with the error shown): a partial cleanup that deletes controller SAs
# while their releases still run is worse than none.
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
#   2 — pre-destroy cleanup failed but destroy continued and succeeded
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
      # Print the leading comment block (minus the shebang).
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

cd "${TF_DIR}" || exit 1

CLEANUP_FAILED=0
cleanup_error() {
  echo "    ERROR: $*" >&2
  CLEANUP_FAILED=1
}

NS="kube-system"
# Release names that were present and failed to uninstall (space-delimited;
# bash 3.2-compatible, no associative arrays).
FAILED_RELEASES=" "

# helm_release_present <namespace> <release>: 0 = present, 1 = absent.
# Uses the listing captured by helm_refresh_list (errors there are fatal for
# the cleanup, so "absent" really means absent, never "helm errored").
HELM_LIST_KS=""
helm_refresh_list() {
  # --all: also match releases stuck in pending-* / uninstalling / failed.
  HELM_LIST_KS="$("${HELM[@]}" list -n "${NS}" --all --short)"
}
helm_release_present() {
  printf '%s\n' "${HELM_LIST_KS}" | grep -qx "$1"
}

# helm_uninstall <release> <timeout>
helm_uninstall() {
  local release="$1" timeout="$2"
  if helm_release_present "${release}"; then
    echo "  - uninstalling ${release}"
    if ! "${HELM[@]}" uninstall "${release}" -n "${NS}" --wait --timeout "${timeout}"; then
      cleanup_error "helm uninstall ${release} failed"
      FAILED_RELEASES="${FAILED_RELEASES}${release} "
      return 1
    fi
  else
    echo "  - ${release}: not installed, skip"
  fi
  return 0
}

release_failed() {
  case "${FAILED_RELEASES}" in *" $1 "*) return 0 ;; esac
  return 1
}

# kdelete <description> <kubectl delete args...>: --ignore-not-found makes
# "absent" a success, so any non-zero exit is a real error — shown, not
# swallowed.
kdelete() {
  local what="$1"; shift
  if ! "${KUBECTL[@]}" delete "$@" --ignore-not-found; then
    cleanup_error "failed to delete ${what}"
    return 1
  fi
}

# karpenter_crs_remaining: prints remaining Karpenter CRs (empty = none).
# Returns non-zero if the API could not be queried.
karpenter_crs_remaining() {
  local kinds="" crd
  for crd in nodepools.karpenter.sh nodeclaims.karpenter.sh ec2nodeclasses.karpenter.k8s.aws; do
    local found
    found="$("${KUBECTL[@]}" get crd "${crd}" --ignore-not-found -o name)" || return 1
    [ -n "${found}" ] && kinds="${kinds:+${kinds},}${crd}"
  done
  [ -z "${kinds}" ] && return 0
  "${KUBECTL[@]}" get "${kinds}" -o name
}

# Resolve cluster name.
CLUSTER_NAME="${CLUSTER_NAME:-$(terraform output -raw cluster_name 2>/dev/null || true)}"
if [ -z "${CLUSTER_NAME}" ]; then
  echo "WARN: cannot resolve cluster_name from terraform output; skipping helm/kubectl cleanup."
  echo "      Run 'terraform destroy' directly if the state is already broken."
else
  REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
  echo "==> Resolving kubeconfig for ${CLUSTER_NAME} in ${REGION}..."
  if aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" --alias "${CLUSTER_NAME}" >/dev/null; then
    # kubectl takes --context, helm takes --kube-context. helm rejects
    # --context ("unknown flag"), which used to be swallowed by 2>/dev/null
    # and made every release look "not installed".
    KUBECTL=(kubectl --context="${CLUSTER_NAME}")
    HELM=(helm --kube-context="${CLUSTER_NAME}")

    echo "==> Checking helm / kubectl access..."
    if ! "${KUBECTL[@]}" get namespace "${NS}" -o name >/dev/null; then
      cleanup_error "kubectl cannot reach the cluster (context ${CLUSTER_NAME}); skipping helm/kubectl cleanup"
    elif ! helm_refresh_list; then
      cleanup_error "helm cannot list releases in ${NS} (context ${CLUSTER_NAME}); skipping helm/kubectl cleanup"
    else
      echo "==> Karpenter: NodePools / EC2NodeClasses first, controller last..."
      # karpenter-pools (bedag/raw) renders the NodePools / EC2NodeClasses.
      # Their finalizers are cleared by the Karpenter controller, which needs
      # its ServiceAccount (Pod Identity) to terminate instances — so the
      # controller and SA must outlive every Karpenter CR.
      helm_uninstall karpenter-pools 10m
      # Stray CRs (kubectl-applied, or left by a failed uninstall). Deleting
      # a NodePool deletes its NodeClaims (= instances); an EC2NodeClass
      # waits on the termination finalizer until its NodeClaims are gone.
      KARPENTER_CLEAN=1
      if ! remaining="$(karpenter_crs_remaining)"; then
        cleanup_error "cannot list Karpenter custom resources"
        KARPENTER_CLEAN=0
      elif [ -n "${remaining}" ]; then
        echo "  - deleting remaining Karpenter custom resources:"
        printf '%s\n' "${remaining}" | sed 's/^/      /'
        "${KUBECTL[@]}" delete nodepools.karpenter.sh --all --ignore-not-found --timeout=5m \
          || cleanup_error "failed to delete Karpenter NodePools"
        "${KUBECTL[@]}" delete ec2nodeclasses.karpenter.k8s.aws --all --ignore-not-found --timeout=10m \
          || cleanup_error "failed to delete Karpenter EC2NodeClasses"
        if ! remaining="$(karpenter_crs_remaining)"; then
          cleanup_error "cannot list Karpenter custom resources"
          KARPENTER_CLEAN=0
        elif [ -n "${remaining}" ]; then
          cleanup_error "Karpenter custom resources still present:"
          printf '%s\n' "${remaining}" | sed 's/^/      /' >&2
          KARPENTER_CLEAN=0
        fi
      fi
      if [ "${KARPENTER_CLEAN}" -eq 1 ] && release_failed karpenter-pools; then
        # The CRs are gone, so a release left in "uninstalling" can now be
        # removed without waiting on finalizers.
        helm_refresh_list || cleanup_error "helm list failed"
        if helm_release_present karpenter-pools; then
          echo "  - retrying uninstall of karpenter-pools (its resources are gone)"
          if "${HELM[@]}" uninstall karpenter-pools -n "${NS}" --timeout 2m; then
            FAILED_RELEASES="${FAILED_RELEASES// karpenter-pools / }"
          else
            cleanup_error "helm uninstall karpenter-pools failed again"
          fi
        fi
      fi
      if [ "${KARPENTER_CLEAN}" -eq 1 ] && ! release_failed karpenter-pools; then
        helm_uninstall karpenter 5m
      else
        cleanup_error "keeping the karpenter release and sa/karpenter: Karpenter CRs are not fully gone, and the controller is needed to clear their finalizers. Fix them, then re-run this script."
        FAILED_RELEASES="${FAILED_RELEASES}karpenter "
      fi

      echo "==> Helm uninstall (reverse install order)..."
      # Other releases are independent but share the same cluster.
      # Added 2026-05-22: dcgm-exporter, node-problem-detector (standard mode);
      # gpu-operator lives in its own namespace and is handled below.
      # Added with Neuron support: neuron-helm-chart (modules/eks-neuron-stack,
      # install_neuron_stack = true) — installed after the core addons, so it
      # goes before aws-load-balancer-controller / cluster-autoscaler.
      # neuron-monitor-servicemonitor (bedag/raw, install_neuron_monitor +
      # neuron_monitor_service_monitor) goes first: it depends on the Neuron
      # stack's Service.
      for release in nvidia-device-plugin dcgm-exporter node-problem-detector neuron-monitor-servicemonitor neuron-helm-chart aws-load-balancer-controller cluster-autoscaler aws-fsx-csi-driver; do
        helm_uninstall "${release}" 5m
      done

      # Operator-mode artifacts: helm release lives in its own ns/gpu-operator,
      # and the namespace itself must be removed for a clean state.
      if ! gpu_op="$("${HELM[@]}" list -n gpu-operator --all --short)"; then
        cleanup_error "helm cannot list releases in gpu-operator"
      elif printf '%s\n' "${gpu_op}" | grep -qx "gpu-operator"; then
        echo "  - uninstalling gpu-operator (ns=gpu-operator)"
        "${HELM[@]}" uninstall gpu-operator -n gpu-operator --wait --timeout 10m \
          || cleanup_error "helm uninstall gpu-operator failed"
      fi
      kdelete "ns/gpu-operator" namespace gpu-operator --timeout=120s

      # Standalone health-check resources (kubectl-managed in bash path,
      # terraform-managed in tf path — but safe-destroy runs before the
      # helm/k8s API is torn down, so pre-clean either way).
      kdelete "ds/gpu-health-check" daemonset gpu-health-check -n "${NS}" --timeout=60s
      kdelete "clusterrolebinding/gpu-health-check" clusterrolebinding gpu-health-check --timeout=30s
      kdelete "clusterrole/gpu-health-check" clusterrole gpu-health-check --timeout=30s
      kdelete "sa/gpu-health-check" serviceaccount gpu-health-check -n "${NS}" --timeout=30s

      # Neuron-node EFA device plugin (kubernetes_daemon_set_v1 in
      # modules/eks-neuron-stack; separate from the GPU EFA DaemonSet).
      kdelete "ds/aws-efa-k8s-device-plugin-neuron" daemonset aws-efa-k8s-device-plugin-neuron -n "${NS}" --timeout=60s

      # neuron-monitor (install_neuron_monitor; kubernetes_* resources in
      # modules/eks-neuron-stack). RBAC objects exist only with
      # neuron_monitor_pod_attribution; --ignore-not-found covers both cases.
      kdelete "ds/neuron-monitor" daemonset neuron-monitor -n "${NS}" --timeout=60s
      kdelete "svc/neuron-monitor" service neuron-monitor -n "${NS}" --timeout=30s
      kdelete "clusterrolebinding/neuron-monitor" clusterrolebinding neuron-monitor --timeout=30s
      kdelete "clusterrole/neuron-monitor" clusterrole neuron-monitor --timeout=30s
      kdelete "sa/neuron-monitor" serviceaccount neuron-monitor -n "${NS}" --timeout=30s

      echo "==> Deleting ServiceAccounts that Terraform won't clean by itself..."
      # <sa>:<owning release>. An SA is deleted only once its release is
      # gone: a controller that loses its SA loses its AWS credentials and
      # can no longer clear the finalizers it owns.
      for pair in karpenter:karpenter cluster-autoscaler:cluster-autoscaler \
                  aws-load-balancer-controller:aws-load-balancer-controller \
                  fsx-csi-controller-sa:aws-fsx-csi-driver; do
        sa="${pair%%:*}"; release="${pair#*:}"
        if release_failed "${release}"; then
          echo "  - sa/${sa}: kept (release ${release} is still installed)"
          continue
        fi
        kdelete "sa/${sa}" serviceaccount "${sa}" -n "${NS}" --timeout=30s
      done
    fi
  else
    cleanup_error "aws eks update-kubeconfig failed; skipping helm/kubectl cleanup."
    echo "      The cluster API may already be down. Continuing to terraform destroy."
  fi
fi

echo ""
echo "==> Running terraform destroy..."
terraform destroy ${AUTO_APPROVE:+"${AUTO_APPROVE}"} ${VAR_FILE:+"${VAR_FILE}"} -input=false
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

if [ "${CLEANUP_FAILED}" -ne 0 ]; then
  echo ""
  echo "==> terraform destroy succeeded, but the pre-destroy cleanup reported errors (see ERROR lines above)."
  exit 2
fi

echo ""
echo "==> Clean teardown complete."
echo "    Don't forget the bootstrap-vpc/ stack:"
echo "      cd bootstrap-vpc && terraform destroy"
