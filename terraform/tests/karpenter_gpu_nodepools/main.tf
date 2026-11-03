# Fixture directory for the Karpenter GPU NodePool tests.
#
# Intentionally empty: every run block points `module { source = ... }` at
# modules/eks-karpenter so assertions can address its own resources. All
# providers are mocked — no AWS / cluster access.
