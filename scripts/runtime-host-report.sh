#!/usr/bin/env bash

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$META_DIR/.env" ]; then
  # shellcheck source=/dev/null
  source "$META_DIR/.env"
fi

report_path() {
  local label="$1"
  local path="$2"

  printf '[path] %s\n' "$label"
  printf '  host_path: %s\n' "$path"

  if [ ! -e "$path" ]; then
    printf '  exists: no\n\n'
    return
  fi

  printf '  exists: yes\n'
  printf '  host_stat: '
  stat -c '%u:%g %A %n' "$path"
  printf '  fs_type: '
  stat -f -c '%T' "$path"
  printf '\n'
}

mount_probe() {
  local label="$1"
  local host_path="$2"
  local container_path="$3"
  local probe_path="$4"
  local probe_output

  printf '[mount] %s\n' "$label"
  printf '  host_path: %s\n' "$host_path"
  printf '  container_path: %s\n' "$container_path"
  printf '  probe_path: %s\n' "$probe_path"

  if [ ! -e "$host_path" ]; then
    printf '  exists: no\n\n'
    return
  fi

  printf '  as_node:\n'
  if probe_output="$(docker run --rm -u node -v "$host_path:$container_path" node:lts-trixie bash -lc "id; stat -c '%u:%g %A %n' '$container_path'; mkdir -p '$probe_path'" 2>&1)"; then
    printf '%s\n' "$probe_output" | sed 's/^/    /'
  else
    printf '%s\n' "$probe_output" | sed 's/^/    /'
  fi

  printf '  as_root:\n'
  if probe_output="$(docker run --rm -v "$host_path:$container_path" node:lts-trixie bash -lc "id; stat -c '%u:%g %A %n' '$container_path'; mkdir -p '$probe_path'" 2>&1)"; then
    printf '%s\n' "$probe_output" | sed 's/^/    /'
  else
    printf '%s\n' "$probe_output" | sed 's/^/    /'
  fi
  printf '\n'
}

printf '== Runtime Host Report ==\n'
printf 'generated_at: %s\n' "$(date -Is)"
printf 'hostname: %s\n' "$(hostname)"
printf 'pwd: %s\n' "$META_DIR"
printf 'user: '
id
printf 'kernel: %s\n' "$(uname -srmo)"
printf '\n'

printf '[docker]\n'
printf '  context: %s\n' "$(docker context show)"
printf '  security_driver_os_kernel: %s\n' "$(docker info --format '{{json .SecurityOptions}} {{.Driver}} {{.OperatingSystem}} {{.KernelVersion}}')"
printf '  rootless: %s\n' "$(docker info --format '{{join .SecurityOptions ","}}' | grep -q 'name=rootless' && echo yes || echo no)"
printf '\n'

report_path 'meta_root' "$META_DIR"
report_path 'astro_site_dev' "${ASTRO_SITE_DIR:-}"
report_path 'astro_site_staging' "${ASTRO_STAGING_SITE_DIR:-}"
report_path 'astro_build_workdir' "${ASTRO_BUILD_WORKDIR_HOST_DIR:-}"
report_path 'orchestrator_root' "${ORCHESTRATOR_HOST_DIR:-}"
report_path 'static_output_root' "${STATIC_SERVER_SITE_DIR:-}"

mount_probe 'astro_dev_bind' "${ASTRO_SITE_DIR:-}" '/app' '/app/node_modules/runtime-host-report'
mount_probe 'static_output_bind' "${STATIC_SERVER_SITE_DIR:-}" '/shared/static' '/shared/static/dev/runtime-host-report'
