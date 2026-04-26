#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/madeofpeople/abcnorio.org"
WORK_DIR="$ROOT/vibe/old dot links"
INDEX_URL="https://www.abcnorio.org/wp-sitemap.xml"
SOURCE_HOST="https://www.abcnorio.org"
OLD_HOST="http://old.abcnorio.org"

SITEMAP_INDEX_FILE="$WORK_DIR/external-sitemap-index.xml"
SITEMAP_URLS_FILE="$WORK_DIR/external-sitemap-urls.txt"
PAGE_URLS_FILE="$WORK_DIR/external-page-urls.txt"
PATHS_FILE="$WORK_DIR/external-internal-paths.txt"
REPORT_FILE="$WORK_DIR/old-dot-links-report.md"

mkdir -p "$WORK_DIR"

curl -L -sS --max-time 30 "$INDEX_URL" > "$SITEMAP_INDEX_FILE"
grep -oE '<loc>[^<]+' "$SITEMAP_INDEX_FILE" | sed 's#<loc>##' | sort -u > "$SITEMAP_URLS_FILE"

: > "$PAGE_URLS_FILE"
while IFS= read -r sitemap_url; do
  [[ -z "$sitemap_url" ]] && continue
  tmp_file="$WORK_DIR/.sitemap.tmp.xml"
  curl -L -sS --max-time 30 "$sitemap_url" > "$tmp_file"
  grep -oE '<loc>[^<]+' "$tmp_file" | sed 's#<loc>##' >> "$PAGE_URLS_FILE"
done < "$SITEMAP_URLS_FILE"

sort -u "$PAGE_URLS_FILE" -o "$PAGE_URLS_FILE"

: > "$PATHS_FILE"
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  case "$url" in
    https://www.abcnorio.org/*|http://www.abcnorio.org/*|https://abcnorio.org/*|http://abcnorio.org/*)
      ;;
    *)
      continue
      ;;
  esac

  path="${url#https://www.abcnorio.org}"
  path="${path#http://www.abcnorio.org}"
  path="${path#https://abcnorio.org}"
  path="${path#http://abcnorio.org}"

  if [[ -z "$path" ]]; then
    path="/"
  fi

  if [[ "$path" != /* ]]; then
    path="/$path"
  fi

  echo "$path" >> "$PATHS_FILE"
done < "$PAGE_URLS_FILE"

sort -u "$PATHS_FILE" -o "$PATHS_FILE"

total=0
matches=0
generated_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

{
  echo "# Old Dot Links Report"
  echo
  echo "Generated: $generated_at"
  echo
  echo "Source scraped: $SOURCE_HOST via sitemap"
  echo "Criteria: path fails on $SOURCE_HOST but succeeds on $OLD_HOST"
  echo
  echo "| Path | www.abcnorio.org | old.abcnorio.org |"
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

  code_source="$(curl -L -sS -o /dev/null -w "%{http_code}" --max-time 20 "$SOURCE_HOST$path" || echo 000)"
  code_old="$(curl -L -sS -o /dev/null -w "%{http_code}" --max-time 20 "$OLD_HOST$path" || echo 000)"

  if is_broken "$code_source" && is_working "$code_old"; then
    matches=$((matches + 1))
    printf '| %s | %s | %s |\n' "$path" "$code_source" "$code_old" >> "$REPORT_FILE"
  fi
done < "$PATHS_FILE"

{
  echo
  echo "Total sitemap URLs checked: $total"
  echo "Matches (broken on source, works on old): $matches"
} >> "$REPORT_FILE"

echo "Report written: $REPORT_FILE"
echo "Sitemap index: $SITEMAP_INDEX_FILE"
echo "Sitemaps discovered: $SITEMAP_URLS_FILE"
echo "Page URLs discovered: $PAGE_URLS_FILE"
echo "Paths checked: $PATHS_FILE"
