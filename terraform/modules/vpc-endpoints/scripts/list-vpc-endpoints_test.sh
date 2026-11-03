#!/usr/bin/env bash
# Offline regression test for list-vpc-endpoints.sh (no AWS access).
#
#   bash terraform/modules/vpc-endpoints/scripts/list-vpc-endpoints_test.sh
#
# A stub `aws` on PATH replays a canned describe-vpc-endpoints response, so
# the real jq filtering is exercised. The key regression: endpoints THIS
# stack created (identified by the module's exact Name tag) must NOT be
# reported as pre-existing — otherwise the second plan of a greenfield stack
# subtracts them from the create set and destroys every endpoint it owns.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/list-vpc-endpoints.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# The stub ignores --query and returns already-projected rows, matching
# the script's query: [VpcEndpointId, VpcEndpointType, ServiceName, State, Tags]
cat > "$WORK/bin/aws" <<'STUB'
#!/usr/bin/env bash
cat "$AWS_STUB_RESPONSE"
STUB
chmod +x "$WORK/bin/aws"

R=ap-south-2
P="com.amazonaws.$R"
row() { # id type service state name
  local tags='null'
  [ -n "${5:-}" ] && tags="[{\"Key\":\"Name\",\"Value\":\"$5\"}]"
  printf '["%s","%s","%s","%s",%s]' "$1" "$2" "$3" "$4" "$tags"
}

fail=0
check() { # desc response-json expected-output
  printf '%s\n' "$2" > "$WORK/resp.json"
  local got
  got=$(PATH="$WORK/bin:$PATH" AWS_STUB_RESPONSE="$WORK/resp.json" bash "$SCRIPT" vpc-123 "$R" mycluster)
  if [ "$got" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: $3"; echo "       got:  $got"; fail=1; fi
}

check "greenfield: no endpoints" \
  "[]" \
  '{"interface_services":"","s3_gateway_present":"false"}'

check "re-plan: only our own endpoints -> nothing pre-existing (the bug)" \
  "[$(row e1 Interface "$P.eks" available mycluster-eks-endpoint),$(row e2 Interface "$P.ecr.dkr" available mycluster-ecr.dkr-endpoint),$(row e3 Gateway "$P.s3" available mycluster-s3-gateway-endpoint)]" \
  '{"interface_services":"","s3_gateway_present":"false"}'

check "brownfield: foreign endpoints are still skipped" \
  "[$(row f1 Interface "$P.sts" available network-team-sts),$(row f2 Interface "$P.ecr.api" available),$(row f3 Gateway "$P.s3" available)]" \
  '{"interface_services":"ecr.api,sts","s3_gateway_present":"true"}'

check "mixed: ours excluded, foreign kept" \
  "[$(row e1 Interface "$P.eks" available mycluster-eks-endpoint),$(row f1 Interface "$P.sts" available network-team-sts),$(row e3 Gateway "$P.s3" available mycluster-s3-gateway-endpoint)]" \
  '{"interface_services":"sts","s3_gateway_present":"false"}'

check "another cluster's module-named endpoints count as foreign" \
  "[$(row o1 Interface "$P.eks" available othercluster-eks-endpoint),$(row o2 Gateway "$P.s3" available othercluster-s3-gateway-endpoint)]" \
  '{"interface_services":"eks","s3_gateway_present":"true"}'

check "non-alive and non-AWS-service endpoints are ignored" \
  "[$(row d1 Interface "$P.logs" deleted),$(row x1 Interface "com.amazonaws.vpce.$R.vpce-svc-0abc" available)]" \
  '{"interface_services":"","s3_gateway_present":"false"}'

exit $fail
