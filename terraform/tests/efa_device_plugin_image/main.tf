# Fixture directory for the EFA device-plugin image registry tests.
#
# Intentionally empty: every run block in efa_device_plugin_image.tftest.hcl
# points `module { source = ... }` at modules/eks-gpu-stack so assertions can
# address its own resources. All providers are mocked — no AWS / cluster.
