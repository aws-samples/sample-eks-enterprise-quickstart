# Fixture directory for the ALB controller IAM policy sourcing tests.
#
# Intentionally empty: every run block in alb_iam_policy.tftest.hcl points
# `module { source = ... }` at modules/eks-addons so assertions can address
# its own resources. All providers are mocked — no AWS / GitHub access.
