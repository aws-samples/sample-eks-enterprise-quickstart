# Fixture directory for the gpu-instance-catalog pure-function tests.
#
# Intentionally empty: every run block in gpu_instance_catalog.tftest.hcl
# points `module { source = ... }` at modules/gpu-instance-catalog so
# assertions can address its outputs directly. No providers at all — the
# catalog is pure locals.
