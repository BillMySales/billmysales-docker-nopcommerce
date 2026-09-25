#!/bin/sh
# shellcheck disable=SC2153 # variables set by compose
# Installs nopCommerce on the first `docker compose up` and applies the store
# settings on every run; safe to repeat. Runs as root (volumes' owners);
# nopCommerce runs as the image's app user.
# - App_Data: the image's files (installer resources, localization, fonts,
#   GeoIP database) copied to the app_data volume when the image changes,
#   keeping the installation's appsettings.json, plugins.json and
#   DataProtection keys.
# - Empty database: nopCommerce has no CLI installer, so setup starts it on
#   127.0.0.1:8080 and submits its installation form (/install) like a
#   browser would; then restarts it once (plugins are installed on the next
#   start, as after the web installer). With a new image, started once so
#   that nopCommerce runs its database migrations (it does on startup).
# - scripts/configure.sql: store URL, SMTP and store settings.
set -eu
cd /app

app_data=/app/App_Data
image_data=/usr/local/share/nop-app-data
base=http://127.0.0.1:8080
export PGHOST="${DB_HOST}" PGPORT="${DB_PORT}" PGUSER="${DB_USER}" PGPASSWORD="${DB_PASSWORD}" PGDATABASE="${DB_NAME}"

# Starts nopCommerce in the background as app (pid in $nop_pid); $1 = "install"
# to start it without a database connection (the installer's mode).
start_nop() {
    if [ "$1" = install ]; then
        su-exec app env -u ConnectionStrings__ConnectionString ASPNETCORE_URLS="${base}" \
            dotnet Nop.Web.dll > /tmp/nop.log 2>&1 &
    else
        ASPNETCORE_URLS="${base}" su-exec app sh /usr/local/share/stack/scripts/entrypoint.sh \
            > /tmp/nop.log 2>&1 &
    fi
    nop_pid=$!
    for _ in $(seq 180); do
        if curl -fsS -o /dev/null "${base}/$2"; then
            return 0
        fi
        if ! kill -0 "${nop_pid}" 2>/dev/null; then
            cat /tmp/nop.log >&2
            echo "nopCommerce exited" >&2
            exit 1
        fi
        sleep 2
    done
    tail -50 /tmp/nop.log >&2
    echo "nopCommerce didn't answer on /$2" >&2
    exit 1
}

stop_nop() {
    kill "${nop_pid}"
    wait "${nop_pid}" || true
}

url_host="$(echo "${NOP_URL}" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')"
if [ "${url_host}" != "${NOP_HOST}" ]; then
    echo "NOP_HOST (${NOP_HOST}) must be the host name of NOP_URL (${url_host})" >&2
    exit 1
fi

echo "==> App_Data"
build="$(cat "${image_data}/.build")"
new_image=false
if [ "$(cat "${app_data}/.build" 2>/dev/null || true)" != "${build}" ]; then
    new_image=true
    echo "Copying the image's App_Data (${build})"
    (cd "${image_data}" && tar -cf - --exclude=./appsettings.json --exclude=./plugins.json \
        --exclude=./DataProtectionKeys --exclude=./TempUploads --exclude=./.build .) |
        tar -C "${app_data}" -xf -
    mkdir -p "${app_data}/DataProtectionKeys" "${app_data}/TempUploads"
    # Build id last: an interrupted copy is repeated.
    cp "${image_data}/.build" "${app_data}/.build"
fi
for dir in "${app_data}" /app/wwwroot/images/uploaded /app/wwwroot/images/thumbs; do
    find "${dir}" ! -user app -exec chown app:app {} +
done

# Separate assignment: with `set -e`, a failing query stops setup here.
installed="$(psql -XAtc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND lower(table_name) = 'store'")"
if [ "${installed}" = 0 ]; then
    echo "==> Installing nopCommerce ${NOP_VERSION} (web installer)"
    # nopCommerce creates it only when its installer creates the database;
    # here the PostgreSQL image does.
    psql -XAqc "CREATE EXTENSION IF NOT EXISTS citext"
    start_nop install install
    jar=/tmp/install.cookies
    token="$(curl -fsS -c "${jar}" -b "${jar}" "${base}/install" |
        sed -n 's/.*name="__RequestVerificationToken" type="hidden" value="\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "${token}" ]; then
        echo "No antiforgery token on /install" >&2
        exit 1
    fi
    curl -fsS -c "${jar}" -b "${jar}" -o /tmp/install.html "${base}/install" \
        --data-urlencode "__RequestVerificationToken=${token}" \
        --data-urlencode "AdminEmail=${NOP_ADMIN_EMAIL}" \
        --data-urlencode "AdminPassword=${NOP_ADMIN_PASSWORD}" \
        --data-urlencode "ConfirmPassword=${NOP_ADMIN_PASSWORD}" \
        --data-urlencode "DataProvider=PostgreSQL" \
        --data-urlencode "ConnectionStringRaw=true" \
        --data-urlencode "ConnectionString=Host=${DB_HOST};Port=${DB_PORT};Database=${DB_NAME};Username=${DB_USER};Password=\"$(printf '%s' "${DB_PASSWORD}" | sed 's/"/""/g')\"" \
        --data-urlencode "CreateDatabaseIfNotExists=false" \
        --data-urlencode "InstallSampleData=false" \
        --data-urlencode "SubscribeNewsletters=false" \
        --data-urlencode "Country=${NOP_COUNTRY_CULTURE}"
    stop_nop
    installed="$(psql -XAtc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND lower(table_name) = 'store'")"
    if [ "${installed}" = 0 ]; then
        sed -n 's/.*class="[^"]*validation-summary-errors[^"]*"[^>]*>\(.*\)/\1/p' /tmp/install.html | sed 's/<[^>]*>//g' | head -5 >&2
        tail -30 /tmp/nop.log >&2
        echo "The installation failed" >&2
        exit 1
    fi
    echo "==> First start (installs the plugins)"
    start_nop run ""
    stop_nop
elif [ "${new_image}" = true ]; then
    # nopCommerce migrates its database when it starts: do it here, before
    # the settings, so a failed upgrade stops setup.
    echo "==> New image: start nopCommerce once (database migrations)"
    start_nop run ""
    stop_nop
fi

echo "==> Store settings"
sh /usr/local/share/stack/scripts/configure.sh

echo "==> Done: nopCommerce ${NOP_VERSION}"
echo "    Store: ${NOP_URL}"
echo "    Admin: ${NOP_URL}/admin (${NOP_ADMIN_EMAIL})"
