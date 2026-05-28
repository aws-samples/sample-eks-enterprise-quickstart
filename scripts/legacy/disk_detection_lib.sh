#!/bin/bash
# disk_detection_lib.sh — NVMe disk classification snippets for node user-data.
#
# Rationale: on AWS, EBS volumes and Instance Store disks both appear as
# unpartitioned NVMe devices. Using "first nvme with no partitions" as the
# data-disk heuristic silently picks Instance Store on families like
# *d / *gd / i4g / i3en, which is ephemeral and gets wiped on stop/start.
# We disambiguate via /sys/block/nvme*n1/device/model:
#   EBS            -> "Amazon Elastic Block Store"
#   Instance Store -> "Amazon EC2 NVMe Instance Storage"
#
# This library exports shell snippets (not functions) because the code runs
# on the node inside user-data, before any scripts can be fetched. Callers
# splice the snippet into an unquoted heredoc when constructing user-data:
#
#   source "${SCRIPT_DIR}/disk_detection_lib.sh"
#   cat > "${USERDATA_FILE}" <<USERDATA
#   #!/bin/bash
#   ${EBS_DATA_DISK_DETECT_SNIPPET}
#   DISK=\$(detect_ebs_data_disk 60) || exit 1
#   USERDATA
#
# The outer heredoc is unquoted so \${EBS_DATA_DISK_DETECT_SNIPPET} expands
# once; all \$ inside the snippet are preserved literally and interpreted on
# the node.

# Intentionally no `set -e` — library code must not alter caller shell options.

# Shell snippet that defines detect_ebs_data_disk() on the node.
# Selects the first EBS-model NVMe device with no partitions.
# The root disk is always partitioned (nvmeNn1p1), so it's excluded.
# bash 3.2 (macOS) has a parser bug: it incorrectly parses `;;` inside a
# heredoc that is itself inside a command substitution $(...). Use a temp
# file to build the snippet so the heredoc is at the top level of the file,
# which all bash versions handle correctly.
_snippet_file=$(mktemp /tmp/ebs_detect_snippet.XXXXXX)
cat > "$_snippet_file" <<'EBS_DETECT_SNIPPET'
# detect_ebs_data_disk <timeout_seconds>
# Prints the detected EBS data disk device path (e.g. /dev/nvme1n1) to stdout.
# Returns non-zero if no EBS data disk is found within the timeout.
# Distinguishes EBS from Instance Store via /sys/block/*/device/model so we
# never stripe containerd onto ephemeral storage (would be lost on stop/start).
#
# ASSUMPTION: exactly one EBS data disk is attached. If multiple EBS volumes
# are attached in addition to the root volume, this function returns the
# first one in /sys/block enumeration order (kernel enumeration is not
# guaranteed to match the block-device-mapping Nitro assigned). Callers
# that need deterministic selection across multiple EBS volumes should
# use instance metadata block-device-mapping or NVMe vendor-specific
# identifier data instead.
detect_ebs_data_disk() {
  local timeout="${1:-60}"
  local i sys_path model dev parts
  for ((i = 1; i <= timeout; i++)); do
    for sys_path in /sys/block/nvme*n1; do
      [ -e "$sys_path" ] || continue
      model=$(cat "$sys_path/device/model" 2>/dev/null | xargs)
      case "$model" in
        *"Elastic Block Store"*) ;;
        *) continue ;;
      esac
      dev="/dev/$(basename "$sys_path")"
      parts=$(lsblk -no NAME "$dev" 2>/dev/null | wc -l)
      if [ "$parts" -eq 1 ]; then
        printf '%s\n' "$dev"
        return 0
      fi
    done
    echo "Attempt $i/$timeout: EBS data disk not found yet, waiting..." >&2
    sleep 1
  done
  return 1
}
EBS_DETECT_SNIPPET
EBS_DATA_DISK_DETECT_SNIPPET=$(cat "$_snippet_file")
rm -f "$_snippet_file"
unset _snippet_file
export EBS_DATA_DISK_DETECT_SNIPPET
