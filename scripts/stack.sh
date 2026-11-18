#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
usage() {
  echo "Usage: just stack up|down|restart|rebuild|logs [dev|staging|production|shared [role]]" >&2
  exit 1
}
[[ $# -ge 1 && $# -le 3 ]] || usage
action="$1"
environment="${2:-}"
role="${3:-}"
case "$action" in up|down|restart|rebuild|logs) ;; *) usage ;; esac

services=()
case "$environment:$role" in
  :) ;;
  dev:) services=(astro-dev abcwpdev) ;;
  dev:frontend) services=(astro-dev) ;;
  dev:cms) services=(abcwpdev) ;;
  staging:) services=(astro-staging abcwpstaging) ;;
  staging:frontend) services=(astro-staging) ;;
  staging:cms) services=(abcwpstaging) ;;
  production:|production:frontend) services=(astro-prod) ;;
  shared:) services=(proxy web mariadb deploy-orchestrator) ;;
  shared:proxy) services=(proxy) ;;
  shared:web) services=(web) ;;
  shared:database) services=(mariadb) ;;
  shared:orchestrator) services=(deploy-orchestrator) ;;
  *) usage ;;
esac

compose=(docker compose)
if [[ "$environment" == dev ]]; then
  compose+=(--profile dev)
fi

case "$action" in
  up) "${compose[@]}" up -d "${services[@]}" ;;
  down)
    if [[ -z "$environment" ]]; then
      "${compose[@]}" down
    else
      "${compose[@]}" stop "${services[@]}"
    fi ;;
  restart) "${compose[@]}" restart "${services[@]}" ;;
  rebuild)
    "${compose[@]}" build --pull "${services[@]}"
    "${compose[@]}" up -d "${services[@]}" ;;
  logs) "${compose[@]}" logs -f --tail=100 "${services[@]}" ;;
esac
