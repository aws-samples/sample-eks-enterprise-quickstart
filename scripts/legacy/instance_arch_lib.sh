#!/bin/bash
# instance_arch_lib.sh — EC2 instance architecture detection helpers.
#
# Rationale: hand-written regexes on instance-type strings are fragile
# (e.g. `^[a-z][0-9]+g` misses hpc7g, mis-buckets future families).
# AWS is the only reliable source of truth, so we ask EC2 directly.
#
# Public functions:
#   detect_instance_arch <instance-type> [region]
#       Prints one of: arm64 | x86_64
#       (matches AWS EC2 API ProcessorInfo.SupportedArchitectures values
#        and EKS AMI SSM parameter path segments.)
#
#   instance_arch_to_go_arch <arch>
#       Translates arm64 -> arm64, x86_64 -> amd64
#       (matches kubernetes.io/arch node label and container image tags.)
#
# Requirements: aws cli v2, sourced by a script that already exports
# AWS_REGION (or passes region as $2).
#
# Note on performance: each call issues one `aws ec2 describe-instance-types`
# request. Callers typically invoke the function a handful of times per
# run (once per instance type in a nodegroup config), so the API cost is
# negligible. Process-level caching was considered and rejected: because
# callers use `$(detect_instance_arch ...)` (command substitution), any
# cache written in the subshell would be discarded. Adding a real cache
# would require a different API shape (e.g. writing to a named variable)
# and was not worth the complexity for this call volume.

# Intentionally no `set -e` here — library code must not alter the
# caller's shell options. Functions return non-zero on error and the
# caller decides how to handle it.

# detect_instance_arch <instance-type> [region]
# Prints "arm64" or "x86_64" to stdout. Returns non-zero on failure.
detect_instance_arch() {
    local instance_type="${1:?detect_instance_arch: instance type required}"
    local region="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"

    if [ -z "${region}" ]; then
        echo "detect_instance_arch: AWS_REGION not set and no region argument provided" >&2
        return 1
    fi

    # Intentionally no `2>/dev/null` — operators need AWS CLI's error text
    # to tell apart auth denied, throttling, typoed region, typoed instance
    # type, etc. The helper adds one line of its own context; AWS prints
    # the root cause on the preceding line(s).
    local arch
    arch=$(aws ec2 describe-instance-types \
        --instance-types "${instance_type}" \
        --region "${region}" \
        --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' \
        --output text) || {
        echo "detect_instance_arch: cannot determine arch for '${instance_type}' in ${region} (see AWS CLI error above)" >&2
        return 1
    }

    case "${arch}" in
        arm64|x86_64)
            printf '%s\n' "${arch}"
            ;;
        i386)
            # Some legacy types report i386 alongside x86_64; coerce to
            # x86_64 since EKS AMIs are only published for x86_64 / arm64.
            # (Defensive — no currently-supported EKS instance type
            # reports i386 as of 2026-05.)
            printf 'x86_64\n'
            ;;
        None|"")
            echo "detect_instance_arch: instance type '${instance_type}' not found in ${region}" >&2
            return 1
            ;;
        *)
            echo "detect_instance_arch: unsupported architecture '${arch}' for ${instance_type}" >&2
            return 1
            ;;
    esac
}

# instance_arch_to_go_arch <arch>
# Translate AWS architecture name to Go / Kubernetes arch label.
instance_arch_to_go_arch() {
    local arch="${1:?instance_arch_to_go_arch: arch required}"
    case "${arch}" in
        arm64)  printf 'arm64\n' ;;
        x86_64) printf 'amd64\n' ;;
        *)
            echo "instance_arch_to_go_arch: unknown arch '${arch}'" >&2
            return 1
            ;;
    esac
}
