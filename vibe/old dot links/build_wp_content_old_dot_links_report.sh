#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/madeofpeople/abcnorio.org"
PATHS_FILE="$ROOT/vibe/old dot links/wp-content-internal-paths.txt"
REPORT_FILE="$ROOT/vibe/old dot links/old-dot-links-from-wp-content.md"

cd "$ROOT"
docker compose exec -T frank wp --path=/app/web/wp eval-file /app/tmp/extract_internal_paths.php > "$PATHS_FILE"

total=0
matches=0
generated_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

{
  echo "# Old Dot Links From WP Content"
  echo
  echo "Generated: $generated_at"
  echo
  echo "Criteria: link path from WordPress post content fails on https://abcnorio.org but succeeds on http://old.abcnorio.org"
  echo
  echo "| Path | abcnorio.org | old.abcnorio.org |"
  echo "|---|---:|---:|"
} > "$REPORT_FILE"

is_broken() {
  local code="$1"
  [[ "$code" == "000" ]] && return 0
  [[ "$code" =~ ^[45][0-9][0-9]$ ]]
}

is_working() {
  local code="$1"
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  total=$((total + 1))

  code_new="$(curl -L -sS -o /dev/null -w "%{http_code}" --max-time 15 "https://abcnorio.org$path" || echo 000)"
  code_old="$(curl -L -sS -o /dev/null -w "%{http_code}" --max-time 15 "http://old.abcnorio.org$path" || echo 000)"

  if is_broken "$code_new" && is_working "$code_old"; then
    matches=$((matches + 1))
    printf '| %s | %s | %s |\n' "$path" "$code_new" "$code_old" >> "$REPORT_FILE"
  fi
done < "$PATHS_FILE"

{
  echo
  echo "Total internal paths checked: $total"
  echo "Matches (broken on abcnorio.org, works on old.abcnorio.org): $matches"
} >> "$REPORT_FILE"

echo "Report written: $REPORT_FILE"
echo "Paths file: $PATHS_FILE"
