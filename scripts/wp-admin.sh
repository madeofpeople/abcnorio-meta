#!/usr/bin/env bash
# WP admin helpers — interactive user management and composer ops.
# Usage: source scripts/wp-admin.sh
#   OR:  bash scripts/wp-admin.sh <function> [args...]
#
# Functions:
#   usercreate <container> <username> <email> [role]
#   userlist   <container>
#   chpass     <username> <container>
#   compinst   <container>

set -euo pipefail

# Run composer update + install inside a container.
compinst() {
    docker exec -ti "$1" sh -c "cd /app/ && composer update && composer install"
}

# List WP users in a container.
userlist() {
    docker exec -ti "$1" wp user list --allow-root
}

# Change a WP user's password interactively.
chpass() {
    echo "new password:"
    read -rs NEWPASS
    docker exec -ti "$2" wp user update "$1" --user_pass="$NEWPASS" --allow-root
}

# Create a WP user interactively.
usercreate() {
    local CONTAINER_NAME="$1"
    local NAME="$2"
    local EMAIL="$3"
    local ROLE="${4:-editor}"
    echo "Set password for user ${NAME}:"
    read -rs PWD
    docker exec -ti "$CONTAINER_NAME" wp user create "$NAME" "$EMAIL" \
        --role="$ROLE" --user_pass="$PWD" --allow-root
    docker exec -ti "$CONTAINER_NAME" wp user get "$NAME" --allow-root
}

# Allow direct invocation: bash scripts/wp-admin.sh <function> [args...]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    FN="${1:?Usage: scripts/wp-admin.sh <function> [args...]}"
    shift
    "$FN" "$@"
fi
