# AWS Load Balancer Controller IAM policy — v2.14.1

Verbatim copies of the upstream policy documents for every partition, taken
from the release tag:

    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/<file>

| Partition    | File                     |
|--------------|--------------------------|
| `aws`        | `iam_policy.json`        |
| `aws-cn`     | `iam_policy_cn.json`     |
| `aws-us-gov` | `iam_policy_us-gov.json` |
| `aws-iso`    | `iam_policy_iso.json`    |
| `aws-iso-b`  | `iam_policy_isob.json`   |

Used by `modules/eks-addons` when `alb_controller_iam_policy_source = "file"`
(air-gapped / GitHub.com blocked), and by the legacy bash flow before it
falls back to downloading. The directory name must equal
`alb_controller_app_version`: when bumping the controller, add a sibling
directory for the new tag with the same five files (do not edit these in
place — the policy must match the image it is paired with).
