#!/bin/bash
# Backups of the nopCommerce database, App_Data (appsettings.json,
# plugins.json, DataProtection keys: login cookies) and uploaded files.
#
#   backup.sh            # loop: back up now, then every BACKUP_INTERVAL_HOURS
#   backup.sh now        # one backup
#   backup.sh list       # list backups
#   backup.sh restore <timestamp>   # restore database, App_Data and uploads
#   backup.sh health     # healthcheck: last backup is recent enough
#
# Files: /backups/<timestamp>-db.dump (pg_dump custom format) and
# /backups/<timestamp>-files.tar.gz (app_data/ and uploaded/), deleted after
# BACKUP_KEEP_DAYS days.
set -euo pipefail
# Backups contain password hashes, DataProtection keys and customer data: owner-only.
umask 077

BACKUP_DIR=/backups
DATA_DIR=/data
# Owner of the files: the `app` user of the .NET image.
APP_UID=1654 APP_GID=1654
export PGHOST="${DB_HOST}" PGPORT="${DB_PORT}" PGUSER="${DB_USER}" PGPASSWORD="${DB_PASSWORD}"

backup() {
    local ts tmp
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    echo "==> Backup ${ts}"
    tmp="${BACKUP_DIR}/.${ts}"
    pg_dump --format=custom --no-owner --dbname="${DB_NAME}" --file="${tmp}-db.dump"
    tar -C "${DATA_DIR}" -czf "${tmp}-files.tar.gz" app_data uploaded
    mv "${tmp}-db.dump" "${BACKUP_DIR}/${ts}-db.dump"
    mv "${tmp}-files.tar.gz" "${BACKUP_DIR}/${ts}-files.tar.gz"
    find "${BACKUP_DIR}" -maxdepth 1 \( -name '*-db.dump' -o -name '*-files.tar.gz' \) \
        -mtime +"${BACKUP_KEEP_DAYS}" -delete
    ls -lh "${BACKUP_DIR}/${ts}"-*
}

restore() {
    local ts="${1:?Usage: backup.sh restore <timestamp> (see: backup.sh list)}"
    local db="${BACKUP_DIR}/${ts}-db.dump" files="${BACKUP_DIR}/${ts}-files.tar.gz"
    [ -f "${db}" ] && [ -f "${files}" ] || { echo "Backup ${ts} not found" >&2; exit 1; }
    echo "==> Restoring database ${DB_NAME} from ${db}"
    # A fresh database: nothing created after the backup survives. --force
    # closes nopCommerce's open connections.
    dropdb --if-exists --force --maintenance-db=postgres "${DB_NAME}"
    createdb --maintenance-db=postgres "${DB_NAME}"
    pg_restore --no-owner --exit-on-error --dbname="${DB_NAME}" "${db}"
    echo "==> Restoring App_Data and uploads from ${files}"
    find "${DATA_DIR}/app_data" "${DATA_DIR}/uploaded" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar -C "${DATA_DIR}" -xzpf "${files}"
    chown -R "${APP_UID}:${APP_GID}" "${DATA_DIR}/app_data" "${DATA_DIR}/uploaded"
    echo "==> Restored ${ts}"
}

case "${1:-loop}" in
    now) backup ;;
    list)
        for file in "${BACKUP_DIR}"/*-db.dump; do
            [ -e "${file}" ] && basename "${file}" -db.dump
        done | sort
        ;;
    restore) restore "${2:-}" ;;
    health)
        [ -n "$(find "${BACKUP_DIR}" -maxdepth 1 -name '*-db.dump' \
            -mmin -$(( BACKUP_INTERVAL_HOURS * 60 + 60 )) 2>/dev/null)" ]
        ;;
    loop)
        while :; do
            backup || echo "Backup failed" >&2
            sleep $(( BACKUP_INTERVAL_HOURS * 3600 ))
        done
        ;;
    *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
