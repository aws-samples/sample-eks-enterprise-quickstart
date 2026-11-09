# Fixture directory for the Kubernetes / Karpenter version resolution tests.
#
# Intentionally empty: every run block in k8s_version.tftest.hcl points
# `module { source = ... }` at modules/k8s-version so assertions can address
# its outputs and checks. The EKS lookups are mocked — no AWS access.
