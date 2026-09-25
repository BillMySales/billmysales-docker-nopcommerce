# nopCommerce on the current .NET runtime image.
#
# The official image (nopcommerceteam/nopcommerce) is only rebuilt for each
# nopCommerce release, so its .NET runtime falls behind Microsoft's monthly
# patches; it also runs as root and pulls packages from Alpine edge with
# --allow-untrusted. This image takes the published application from the
# official image (nothing is compiled) and puts it on the current
# mcr.microsoft.com/dotnet/aspnet image, with the same native packages from
# Alpine's stable repositories, running as the image's `app` user (1654).
ARG NOP_VERSION=4.90.8
ARG DOTNET_VERSION=9.0
FROM nopcommerceteam/nopcommerce:${NOP_VERSION} AS nop

FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION}-alpine
ARG NOP_VERSION

# Globalization (es-CL formats) and the native libraries the official image
# installs; curl, su-exec and psql for the stack's setup (nopCommerce has no
# CLI: it's installed through its web installer and configured in the DB).
RUN apk add --no-cache icu-libs icu-data-full tiff libgdiplus libc-dev tzdata gcompat \
        curl su-exec postgresql-client
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

WORKDIR /app
COPY --from=nop --chown=app:app /app /app

# Developer leftovers of the official image (appsettings.json/plugins.json
# of local test installs) must never reach an installation.
RUN set -eux; \
    rm -f /app/App_Data/*.zip; \
    # The image's App_Data, copied to the app_data volume by setup (the
    # volume keeps the installation's appsettings.json, plugins.json and
    # DataProtection keys).
    cp -a /app/App_Data /usr/local/share/nop-app-data; \
    echo "${NOP_VERSION} $(date -u +%Y%m%dT%H%M%SZ)" > /usr/local/share/nop-app-data/.build; \
    chown -R app:app /usr/local/share/nop-app-data

USER app
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    NOP_VERSION=${NOP_VERSION}
EXPOSE 8080
ENTRYPOINT ["dotnet", "Nop.Web.dll"]
