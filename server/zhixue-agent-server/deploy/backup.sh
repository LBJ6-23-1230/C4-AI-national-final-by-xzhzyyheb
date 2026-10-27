#!/bin/sh
set -eu
# libpq service files avoid exposing credentials in the process list.
: "${PGSERVICE:?configure a backup role in ~/.pg_service.conf}"
: "${BACKUP_DIR:?set a protected directory on a separate volume}"
umask 077
mkdir -p "$BACKUP_DIR"
target="$BACKUP_DIR/zhixue-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump --format=custom --no-owner --file="$target"
pg_restore --list "$target" > "$target.manifest"
sha256sum "$target" > "$target.sha256"
printf 'Backup created: %s\n' "$target"
