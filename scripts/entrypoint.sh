#!/bin/sh
# shellcheck disable=SC2153,SC2089,SC2090 # variables set by compose; literal quotes for Npgsql
# Entrypoint of the nopCommerce container: the database connection comes from
# the stack's variables on every start (overriding App_Data/appsettings.json),
# so a DB_PASSWORD change needs no edit of that file.
set -eu

# Password quoted for Npgsql (any character, including ";").
password="$(printf '%s' "${DB_PASSWORD}" | sed 's/"/""/g')"
ConnectionStrings__DataProvider=postgresql
ConnectionStrings__ConnectionString="Host=${DB_HOST};Port=${DB_PORT};Database=${DB_NAME};Username=${DB_USER};Password=\"${password}\""
export ConnectionStrings__DataProvider ConnectionStrings__ConnectionString

exec dotnet Nop.Web.dll "$@"
