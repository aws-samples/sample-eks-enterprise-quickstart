# Fixture directory for the AWS Neuron (Trainium / Inferentia) nodegroup tests.
#
# Intentionally empty: every run block in neuron_nodegroup.tftest.hcl points
# `module { source = ... }` at modules/eks-gpu-nodegroup so assertions can
# address its own resources. All providers are mocked — no AWS access.
