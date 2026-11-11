#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
: "${APP_IMAGE:?export an immutable release image tag}"
test -f .env.production
test -f .env.migration
test -f .env.worker
test -f deploy/certs/fullchain.pem
test -f deploy/certs/privkey.pem
docker compose --env-file .env.production config --quiet
docker compose --env-file .env.production pull api worker migrate
docker compose --env-file .env.production --profile tools run --rm migrate
docker compose --env-file .env.production up -d --wait api worker gateway
docker compose --env-file .env.production exec -T gateway nginx -t
docker compose --env-file .env.production exec -T gateway nginx -s reload
printf 'Released %s at %s\n' "$APP_IMAGE" "$(date -u +%FT%TZ)" >> deploy/releases.log
