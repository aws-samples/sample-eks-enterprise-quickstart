# Fixture directory for the AWS Neuron K8s stack tests.
#
# Intentionally empty: every run block in neuron_stack.tftest.hcl points
# `module { source = ... }` at modules/eks-neuron-stack so assertions can
# address its own resources. All providers are mocked — no AWS / cluster.
