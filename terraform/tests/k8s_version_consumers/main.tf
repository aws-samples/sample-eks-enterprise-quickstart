# Fixture directory for the version-dependent consumer tests (Cluster
# Autoscaler matrix rows, Karpenter controller IAM).
#
# Intentionally empty: every run block in k8s_version_consumers.tftest.hcl
# points `module { source = ... }` at the module under test. All providers
# are mocked — no AWS / cluster access.
