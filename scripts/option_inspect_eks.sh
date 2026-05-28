#!/bin/bash
#
# option_inspect_eks.sh — health snapshot of an EKS cluster.
#
# Read-only. Safe to run anytime (post-deploy, before GPU NG, after upgrades).
# Catches the things that go wrong between "Apply complete" and a real
# workload landing: addons inactive, system NG not Ready, helm release
# pending-install, VPC endpoints missing, bastion-side SG/access entry
# half-configured, in-cluster DNS broken, vCPU quota too small for the
# next nodegroup.
#
# Designed to be runnable from either:
#   - dev host (with AWS_PROFILE set + cluster API reachable), or
#   - bastion (kubeconfig auto-generated; tools assumed pre-installed).
#
# Usage:
#   ./scripts/option_inspect_eks.sh
#   CLUSTER_NAME=eks-tf-smoke AWS_REGION=us-west-2 ./scripts/option_inspect_eks.sh
#   BASTION_INSTANCE_ID=i-xxx ./scripts/option_inspect_eks.sh   # check bastion ingress
#
# Exit codes:
#   0 — all PASS (WARN allowed)
#   1 — at least one FAIL
#   2 — ran but couldn't reach cluster API at all (kubeconfig/network)

set -uo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull CLUSTER_NAME / AWS_REGION from .env if not already in env.
if [ -z "${CLUSTER_NAME:-}" ] || [ -z "${AWS_REGION:-}" ]; then
  if [ -f "${SCRIPT_DIR}/0_setup_env.sh" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/0_setup_env.sh" >/dev/null 2>&1 || true
  fi
fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"

if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
  echo "ERROR: CLUSTER_NAME and AWS_REGION must be set (env or scripts/0_setup_env.sh)." >&2
  exit 2
fi

PASS=0; FAIL=0; WARN=0
section() { echo; echo "── $1 ─────────────────────────────"; }
check()   {
  local label="$1"; local rc="$2"; local detail="${3:-}"
  case "$rc" in
    0) printf "  PASS  %s\n" "$label"; PASS=$((PASS+1)) ;;
    1) printf "  FAIL  %s%s\n" "$label" "${detail:+ — $detail}"; FAIL=$((FAIL+1)) ;;
    2) printf "  WARN  %s%s\n" "$label" "${detail:+ — $detail}"; WARN=$((WARN+1)) ;;
  esac
}

# ── kubeconfig (private to this run; doesn't touch user's ~/.kube/config) ──
export KUBECONFIG=/tmp/eks-inspect-$$.kubeconfig
trap 'rm -f "$KUBECONFIG"' EXIT
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 || true

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "ERROR: kubectl can't reach cluster API at $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo 'unknown')." >&2
  echo "       Likely causes: SG ingress missing for this host, cluster destroyed, or DNS broken." >&2
  exit 2
fi

echo "═══════════════════════════════════════════════════════════════════"
echo "EKS inspection — cluster=$CLUSTER_NAME region=$AWS_REGION  $(date -Is)"
echo "═══════════════════════════════════════════════════════════════════"

# ── 1/9 Control plane ────────────────────────────────────────────────
section "[1/9] Control plane"
CL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --output json 2>/dev/null)
STATUS=$(jq -r '.cluster.status' <<<"$CL")
VER=$(jq -r '.cluster.version' <<<"$CL")
PRIV=$(jq -r '.cluster.resourcesVpcConfig.endpointPrivateAccess' <<<"$CL")
PUB=$(jq -r '.cluster.resourcesVpcConfig.endpointPublicAccess' <<<"$CL")
[ "$STATUS" = "ACTIVE" ] && check "status=ACTIVE" 0 || check "status=$STATUS" 1
check "version=$VER" 0
[ "$PRIV" = "true" ] && check "endpoint private=true" 0 || check "endpoint private=$PRIV" 2
case "$PUB" in true) check "endpoint public=true (limited by CIDRs)" 2 ;; false) check "endpoint public=false" 0 ;; esac

# ── 2/9 Managed addons ───────────────────────────────────────────────
section "[2/9] Managed addons"
EXPECT=(vpc-cni kube-proxy eks-pod-identity-agent coredns metrics-server aws-ebs-csi-driver)
for a in "${EXPECT[@]}"; do
  S=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$a" --region "$AWS_REGION" --query 'addon.status' --output text 2>/dev/null || echo MISSING)
  [ "$S" = "ACTIVE" ] && check "addon $a=ACTIVE" 0 || check "addon $a=$S" 1
done

# ── 3/9 System nodegroup ─────────────────────────────────────────────
section "[3/9] System nodegroup"
NG_NAMES=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'nodegroups' --output text 2>/dev/null)
SYS_NG=""
for ng in $NG_NAMES; do
  case "$ng" in *gpu*) continue ;; esac
  SYS_NG="$ng"; break
done
if [ -n "$SYS_NG" ]; then
  S=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$SYS_NG" --region "$AWS_REGION" --query 'nodegroup.status' --output text)
  [ "$S" = "ACTIVE" ] && check "nodegroup $SYS_NG=ACTIVE" 0 || check "nodegroup $SYS_NG=$S" 1
else
  check "system nodegroup detection" 1 "no non-gpu NG found"
fi

NODE_LINES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null || true)
N_TOTAL=$(echo "$NODE_LINES" | grep -c . || true)
N_READY=$(echo "$NODE_LINES" | grep -c " True$" || true)
[ "$N_READY" -gt 0 ] && [ "$N_READY" = "$N_TOTAL" ] && check "nodes Ready $N_READY/$N_TOTAL" 0 || check "nodes Ready $N_READY/$N_TOTAL" 1

# ── 4/9 System node internals (via SSM) ──────────────────────────────
section "[4/9] System node internals (via SSM)"
NODE_INSTANCE=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | sed 's|.*/||')
if [ -n "$NODE_INSTANCE" ]; then
  CMD=$(aws ssm send-command --instance-ids "$NODE_INSTANCE" --region "$AWS_REGION" \
    --document-name "AWS-RunShellScript" --timeout-seconds 60 \
    --parameters '{"commands":["systemctl is-active kubelet containerd 2>&1","echo ---","mount | grep -E \"vg_data|/data|/var/lib/containerd\" || echo no_lvm_mount"]}' \
    --query 'Command.CommandId' --output text 2>/dev/null)
  sleep 5
  OUT=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$NODE_INSTANCE" --region "$AWS_REGION" --query 'StandardOutputContent' --output text 2>/dev/null)
  KUBELET=$(echo "$OUT" | head -1)
  CONTAINERD=$(echo "$OUT" | sed -n '2p')
  HAS_LVM=$(echo "$OUT" | grep -cE 'vg_data|/data|/var/lib/containerd' || true)
  [ "$KUBELET" = "active" ]    && check "kubelet active on $NODE_INSTANCE" 0    || check "kubelet=$KUBELET on $NODE_INSTANCE" 1
  [ "$CONTAINERD" = "active" ] && check "containerd active on $NODE_INSTANCE" 0 || check "containerd=$CONTAINERD on $NODE_INSTANCE" 1
  [ "$HAS_LVM" -ge 1 ]         && check "vg_data LVM mounted (containerd or /data)" 0 || check "no vg_data LVM" 2
else
  check "node sample" 1 "no nodes found"
fi

# ── 5/9 Helm releases + pod health ───────────────────────────────────
section "[5/9] Helm releases + pod health"
for r in cluster-autoscaler aws-load-balancer-controller; do
  S=$(helm list -A -o json 2>/dev/null | jq -r ".[] | select(.name==\"$r\") | .status")
  [ "$S" = "deployed" ] && check "helm $r=deployed" 0 || check "helm $r=${S:-missing}" 1
done

pods_all_running() {
  local sel="$1"
  local phases
  phases=$(kubectl -n kube-system get pods -l "$sel" -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
  [ -n "$phases" ] && ! echo "$phases" | tr ' ' '\n' | grep -vqx "Running"
}
pods_all_running app.kubernetes.io/name=aws-cluster-autoscaler         && check "CA pods Running"  0 || check "CA pods not Running"  2
pods_all_running app.kubernetes.io/name=aws-load-balancer-controller   && check "ALB pods Running" 0 || check "ALB pods not Running" 2

CRASH=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null | head -3 | tr '\n' ' ' || true)
[ -z "$CRASH" ] && check "no Failed/Pending pods" 0 || check "non-Running pods present" 2 "${CRASH}"

# ── 6/9 VPC endpoints ────────────────────────────────────────────────
section "[6/9] VPC endpoints"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
EP_TOTAL=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID --region "$AWS_REGION" --query 'length(VpcEndpoints)' --output text)
EP_AVAIL=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID --region "$AWS_REGION" --query 'length(VpcEndpoints[?State==`available`])' --output text)
[ "$EP_TOTAL" = "$EP_AVAIL" ] && [ "$EP_TOTAL" -ge 5 ] \
  && check "VPC endpoints $EP_AVAIL/$EP_TOTAL available" 0 \
  || check "VPC endpoints $EP_AVAIL/$EP_TOTAL available" 1

# ── 7/9 Cluster SG ingress ───────────────────────────────────────────
section "[7/9] Cluster SG ingress"
CL_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
SELFREF_OK=$(aws ec2 describe-security-groups --group-ids "$CL_SG" --region "$AWS_REGION" \
  --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId=='$CL_SG']]" --output text | wc -l)
[ "$SELFREF_OK" -ge 1 ] && check "cluster SG self-ingress present" 0 || check "cluster SG self-ingress missing" 1

if [ -n "$BASTION_INSTANCE_ID" ]; then
  BAST_SG=$(aws ec2 describe-instances --instance-ids "$BASTION_INSTANCE_ID" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Groups[0].GroupId' --output text 2>/dev/null)
  if [ -n "$BAST_SG" ] && [ "$BAST_SG" != "None" ]; then
    BAST_INGRESS=$(aws ec2 describe-security-groups --group-ids "$CL_SG" --region "$AWS_REGION" \
      --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId=='$BAST_SG']]" --output text | wc -l)
    [ "$BAST_INGRESS" -ge 1 ] && check "bastion SG → cluster SG :443 ingress" 0 || check "bastion ingress missing" 1
  else
    check "bastion SG lookup ($BASTION_INSTANCE_ID)" 2 "instance not found"
  fi
fi

# ── 8/9 Pod Identity associations ────────────────────────────────────
section "[8/9] Pod Identity associations"
PI_LIST=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'associations[].serviceAccount' --output text 2>/dev/null)
for sa in cluster-autoscaler aws-load-balancer-controller ebs-csi-controller-sa; do
  echo "$PI_LIST" | tr '\t' '\n' | grep -qx "$sa" \
    && check "PI assoc $sa" 0 \
    || check "PI assoc $sa missing" 2
done

# ── 9/9 DNS + capacity ───────────────────────────────────────────────
section "[9/9] DNS + capacity"
DNS_OK=$(kubectl run --rm -it --quiet --restart=Never --image=busybox dns-probe-$RANDOM -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null | grep -c "Address" || true)
[ "$DNS_OK" -ge 1 ] && check "in-cluster DNS resolves kubernetes.default" 0 || check "in-cluster DNS broken" 1

SPOT_QUOTA=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-7212CCBC --region "$AWS_REGION" --query 'Quota.Value' --output text 2>/dev/null || echo 0)
SPOT_INT=${SPOT_QUOTA%.*}
if [ "${SPOT_INT:-0}" -ge 192 ]; then
  check "Spot P/G/H/T vCPU quota = $SPOT_INT (≥192 → fits p6-b300)" 0
elif [ "${SPOT_INT:-0}" -ge 32 ]; then
  check "Spot P/G/H/T vCPU quota = $SPOT_INT" 2 "fits g7e/g6e but not p5/p6"
else
  check "Spot P/G/H/T vCPU quota = $SPOT_INT" 1 "may not fit even single GPU node"
fi

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "Result: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "═══════════════════════════════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
