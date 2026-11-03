# Fixture directory for the Pod Identity propagation-wait tests (issue #2).
#
# Intentionally empty: every run block in pod_identity_propagation.tftest.hcl
# points `module { source = ... }` at the module under test, so assertions can
# address that module's own resources (time_sleep.pod_identity_propagation).
# All providers are mocked — no AWS / cluster access, no real sleeping.
