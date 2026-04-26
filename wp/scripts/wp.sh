#!/bin/bash
compinst() {
    docker exec -ti $1 sh -c "cd /app/ && composer update && composer install"
}

plugins_deactivate() {
    docker exec -ti $1 wp plugin deactivate --all
}

chpass() {
    echo "new password:"
    read -s NEWPASS
    docker exec -ti $2 wp user update $1 --user_pass="$NEWPASS"
}

usercreate() {
    CONTAINER_NAME="${1}" 
    NAME="${2}"
    EMAIL="${3}"
    ROLE="${4:-editor}"
    echo "Set password for user ${NAME}:"
    read -s PWD
    docker exec -ti $CONTAINER_NAME wp user create $NAME $EMAIL  --role=$ROLE --user_pass=$PWD --allow-root
    docker exec -ti $CONTAINER_NAME wp user get $NAME --allow-root;
}

userlist() {
    CONTAINER_NAME="${1}" 
    docker exec -ti $CONTAINER_NAME wp user list --allow-root;
}
