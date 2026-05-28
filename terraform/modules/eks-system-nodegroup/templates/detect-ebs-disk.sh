# detect_ebs_data_disk <timeout_seconds>
# Prints the detected EBS data disk device path (e.g. /dev/nvme1n1) to stdout.
# Returns non-zero if no EBS data disk is found within the timeout.
# Distinguishes EBS from Instance Store via /sys/block/*/device/model so we
# never stripe containerd onto ephemeral storage (would be lost on stop/start).
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
