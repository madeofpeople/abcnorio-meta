#!/usr/bin/env bash
# Warm production caches after a container restart.
# Hits the most common /events/listing filter variants and the search API
# through the public domain so requests flow through the full proxy stack.
#
# Warms:
#   - WP object cache (first REST query populates it)
#   - FrankenPHP OPcache (already warm via validate_timestamps=0, but safe to touch)
#   - Caddy keepalive pool (establishes connections to astro-prod + abcwpstaging)
#
# Usage:
#   scripts/warm-cache.sh [host]
#   host default: https://abcnorio.itztlacoliuhqui.org

set -euo pipefail

HOST="${1:-https://abcnorio.itztlacoliuhqui.org}"

URLS=(
    "${HOST}/events/listing?date-filter=ongoing-and-upcoming&order=desc"
    "${HOST}/events/listing?date-filter=ongoing-and-upcoming&order=asc"
    "${HOST}/events/listing?date-filter=past&order=desc"
    "${HOST}/events/listing?date-filter=upcoming&order=desc"
    "${HOST}/events/listing?date-filter=&event_type=&collective_association=punk-hardcore-collective&order=desc"
    "${HOST}/events/listing?date-filter=&event_type=&collective_association=visual-arts-collective&order=desc"
    "${HOST}/events/listing?date-filter=&event_type=&collective_association=zine-library-collective&order=desc"
    "${HOST}/events/listing?date-filter=&event_type=&collective_association=darkroom-collective&order=desc"
    "${HOST}/events/listing?date-filter=&event_type=&collective_association=silkscreen-printshop&order=desc"
    "${HOST}/events/listing?date-filter=&event_type=&collective_association=computer-center&order=desc"
    "${HOST}/search/api?q=show"
    "${HOST}/search/api?q=exhibit"
    "${HOST}/search/api?q=punk"
)

echo "Warming cache: $HOST"

for url in "${URLS[@]}"; do
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "HX-Request: true" \
        -H "HX-Target: event-listing" \
        "$url")
    echo "  $status  $url"
done

echo "Done."
