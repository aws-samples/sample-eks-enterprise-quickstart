# Fixture directory for the root-stack Kubernetes version tests.
#
# Intentionally empty: every run block in root_k8s_version.tftest.hcl points
# `module { source = "../.." }` at the ROOT stack, so the whole module graph
# is planned with mocked providers — no AWS / cluster access.
