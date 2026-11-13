#!/usr/bin/env bash
set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_DIR="$META_DIR/install-seed"

if [[ ! -d "$SEED_DIR" ]]; then
    echo "==> No install-seed directory; skipping content restore."
    exit 0
fi

SQL_FILE="$SEED_DIR/database.sql"
if [[ -f "$SEED_DIR/database.sql.gz" ]]; then
    if [[ -f "$SQL_FILE" ]]; then
        echo "Provide database.sql or database.sql.gz, not both." >&2
        exit 1
    fi
    SQL_FILE="$SEED_DIR/database.sql.gz"
fi
MEDIA_FILE="$SEED_DIR/uploads.tar.gz"
if [[ ! -s "$SQL_FILE" || ! -s "$MEDIA_FILE" ]]; then
    echo "Install seed requires database.sql(.gz) and uploads.tar.gz." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$META_DIR/.env"
: "${DEV_HOST_ROOT:?}" "${STAGING_HOST_ROOT:?}" "${PROJECT_UID:?}" "${PROJECT_GID:?}"

if [[ "$SQL_FILE" == *.gz ]]; then
    gzip -t "$SQL_FILE"
fi
tar -tzf "$MEDIA_FILE" --quoting-style=escape | awk '
    $0 !~ /^uploads(\/|$)/ || $0 ~ /(^|\/)\.\.(\/|$)/ || index($0, "\\") { invalid = 1 }
    END { exit invalid }
' || { echo "Media archive must contain only uploads/ and its contents, without unsafe paths." >&2; exit 1; }
tar -tvzf "$MEDIA_FILE" | awk '
    substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { invalid = 1 }
    END { exit invalid }
' || { echo "Media archive must contain only regular files and directories, not links." >&2; exit 1; }

TARGETS=()
for env in dev staging; do
    root="$DEV_HOST_ROOT"
    [[ "$env" != staging ]] || root="$STAGING_HOST_ROOT"
    uploads="${root%/}/bedrock/web/app/uploads"

    ready=false
    for ((attempt = 0; attempt < 60; attempt++)); do
        if bash "$META_DIR/scripts/wp.sh" "$env" db query 'SELECT 1' --skip-column-names >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done
    if [[ "$ready" != true ]]; then
        echo "[$env] database not ready after 120 seconds; seed not imported." >&2
        exit 1
    fi
    tables="$(bash "$META_DIR/scripts/wp.sh" "$env" db query 'SHOW TABLES' --skip-column-names)"
    if [[ -n "$tables" ]]; then
        echo "[$env] existing database; skipping seed without changing database or uploads."
        continue
    fi
    if [[ -L "$uploads" || ( -e "$uploads" && ! -d "$uploads" ) ]]; then
        echo "[$env] uploads is not a regular directory; refusing seed restore." >&2
        exit 1
    fi
    if [[ -d "$uploads" ]]; then
        contents="$(find "$uploads" -mindepth 1 -print -quit)"
        if [[ -n "$contents" ]]; then
            echo "[$env] uploads is not empty; refusing seed restore." >&2
            exit 1
        fi
    fi
    TARGETS+=("$env")
done

MEDIA_TMP="$(mktemp -d)"
trap 'rm -rf -- "$MEDIA_TMP"' EXIT
tar -xzf "$MEDIA_FILE" --no-same-owner --no-same-permissions -C "$MEDIA_TMP"

for env in "${TARGETS[@]}"; do
    container="abcwp${env}"
    root="$DEV_HOST_ROOT"
    [[ "$env" != staging ]] || root="$STAGING_HOST_ROOT"
    uploads="${root%/}/bedrock/web/app/uploads"

    echo "[$env] restoring install seed..."
    sudo install -d -o "$PROJECT_UID" -g "$PROJECT_GID" -m 2775 "$uploads"
    sudo rsync -rt --chown="$PROJECT_UID:$PROJECT_GID" --chmod=D2775,F0664 "$MEDIA_TMP/uploads/" "$uploads/"
    if [[ "$SQL_FILE" == *.gz ]]; then
        gzip -cd "$SQL_FILE"
    else
        cat "$SQL_FILE"
    fi | docker exec -i "$container" wp --allow-root --path=/app/web/wp db import -
    bash "$META_DIR/scripts/wp.sh" "$env" core is-installed
    bash "$META_DIR/scripts/wp.sh" "$env" plugin activate abcnorio-func
    bash "$META_DIR/scripts/wp.sh" "$env" abcnorio normalize-urls --apply
    bash "$META_DIR/scripts/wp.sh" "$env" transient delete --all
    echo "[$env] seed restored; plugin activated and URLs normalized."
done
