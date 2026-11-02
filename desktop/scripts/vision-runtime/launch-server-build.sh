#!/usr/bin/env bash
# Durable launcher only. Do not run this for a status query or while preparing sources.
set -euo pipefail

vision_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
vision_unit=""
vision_env_file=""
while (($#)); do
  case "$1" in
    --unit)
      (($# >= 2)) || { printf '%s\n' 'Missing unit value' >&2; exit 2; }
      vision_unit="$2"
      shift 2
      ;;
    --env-file)
      (($# >= 2)) || { printf '%s\n' 'Missing environment file value' >&2; exit 2; }
      vision_env_file="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      printf '%s\n' 'Usage: launch-server-build.sh --unit NAME [--env-file CACHED_PRIVATE_ENV] -- build <producer args>' >&2
      exit 2
      ;;
  esac
done
[[ "$vision_unit" =~ ^dinox-vision-runtime-[a-zA-Z0-9_-]+$ && "${1:-}" == build ]] || {
  printf '%s\n' 'Require a unique dinox-vision-runtime-* unit and explicit build action' >&2
  exit 2
}
[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'Run on the build server through its existing root session' >&2; exit 2; }
command -v systemd-run >/dev/null
vision_loaded="$(systemctl show --property=LoadState --value "$vision_unit.service" 2>/dev/null || true)"
[[ -z "$vision_loaded" || "$vision_loaded" == not-found ]] || {
  printf '%s\n' 'Refusing to replace an existing unit; use a new evidence/attempt name' >&2
  exit 2
}
vision_properties=(
  --property=Type=exec
  --property=CPUQuota=100%
  --property=MemoryMax=6G
  --property=MemorySwapMax=0
  --property=CPUAccounting=true
  --property=MemoryAccounting=true
  --property=KillMode=control-group
  --property=TimeoutStartSec=18h
  --property=RuntimeMaxSec=18h
)
if [[ -n "$vision_env_file" ]]; then
  [[ -f "$vision_env_file" && "$vision_env_file" == /* ]] || {
    printf '%s\n' 'Cached Windows/toolchain environment must be an existing absolute file' >&2
    exit 2
  }
  vision_properties+=("--property=EnvironmentFile=$vision_env_file")
fi
systemd-run --quiet --collect --unit="$vision_unit" \
  --working-directory="$vision_script_dir" \
  --setenv=PYTHONDONTWRITEBYTECODE=1 \
  "${vision_properties[@]}" \
  /usr/bin/python3 "$vision_script_dir/vision_runtime.py" "$@"
printf '%s\n' "Started durable unit: $vision_unit.service"
printf '%s\n' 'Two compiler jobs, CPU100%, memory6GiB, no swap. No polling is performed.'
