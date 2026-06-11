#!/usr/bin/env bash
# Build and deploy the docs (Starlight) site to web/static/docs.
# Reads DOCS_HOST_ROOT and STATIC_SERVER_SITE_DIR from .env.

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$META_DIR/.env" ]]; then
    echo "ERROR: Missing required env file: $META_DIR/.env" >&2
    exit 1
fi

source "$META_DIR/.env"

mkdir -p "${STATIC_SERVER_SITE_DIR}docs"
image=$(docker build -q "${DOCS_HOST_ROOT}")
docker run --rm \
    -v "${STATIC_SERVER_SITE_DIR}docs:/app/dist" \
    "$image"
echo "Docs deployed → ${STATIC_SERVER_SITE_DIR}docs"
