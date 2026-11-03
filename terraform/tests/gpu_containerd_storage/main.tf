# Fixture directory for the GPU containerd storage tests (issue #12).
#
# Intentionally empty: every run block in gpu_containerd_storage.tftest.hcl
# points `module { source = ... }` at modules/eks-gpu-nodegroup so
# assertions can address its own resources. All providers are mocked — no
# AWS access.
