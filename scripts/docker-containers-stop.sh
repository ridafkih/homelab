#!/bin/bash

BASE_DIR="docker"
cd "$BASE_DIR" || exit 1

for service_dir in */; do
    service_name="${service_dir%/}"
    
    if [ -d "$service_name" ] && ([ -f "$service_name/docker-compose.yml" ] || [ -f "$service_name/docker-compose.yaml" ]); then
        cd "$service_name"
        docker compose stop
        cd ..
    fi
done
