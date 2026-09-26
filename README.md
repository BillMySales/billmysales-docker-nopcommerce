nopCommerce Docker stack
========================

Docker Compose stack for [nopCommerce](https://www.nopcommerce.com) (open
source e-commerce on ASP.NET Core: store, admin, plugins), usable for local
development and for simple production deployments (a single server).
Maintained by [BillMySales](https://www.billmysales.com).

| Component   | Image                                         | Default version      |
|-------------|-----------------------------------------------|----------------------|
| Web server  | `caddy:<ver>-alpine`                          | 2.11                 |
| nopCommerce | own image (`image/`): the official application on `mcr.microsoft.com/dotnet/aspnet:<ver>-alpine` | 4.90.8 (.NET 9.0) |
| Database    | `postgres:<ver>-alpine`                       | 18                   |
| Mailpit     | `axllent/mailpit` (optional, dev)             | v1.31                |

Why an own image: the official one (`nopcommerceteam/nopcommerce`) is only
rebuilt for nopCommerce releases, so its .NET runtime falls behind
Microsoft's monthly security patches (9.0.19 when 9.0.20 was out); it runs as
root and installs packages from Alpine's edge repositories with
`--allow-untrusted`. `image/Dockerfile` copies the published application from
the official image (nothing is compiled; builds in seconds) onto the current
.NET runtime image, with the same native packages from Alpine's stable
repositories, running as the image's unprivileged `app` user. It also drops
two archives the official image ships by mistake (a developer's local
`appsettings.json`/`plugins.json`). amd64 and arm64; tested on arm64.

nopCommerce 4.90 runs on .NET 9, supported by Microsoft until November 2026;
the next nopCommerce major moves to .NET 10.

PostgreSQL: nopCommerce supports SQL Server, MySQL/MariaDB and PostgreSQL;
its own compose files use `postgres:latest`.

Requirements
------------

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`, 2.24+).
- About 1 GB of disk for the images; 1 GB of RAM for the stack.
- Development: ports 8115, 8415 and 8025 free on the host.
- Production: a server with ports 80 and 443 reachable, and a DNS record for
  the store's domain pointing to it.

Quick start (development)
-------------------------

```shell
cp .env.dev.example .env
docker compose up -d --build   # builds the image the first time
docker compose logs -f setup   # wait for "==> Done" (about a minute)
```

- Store: http://shop.localhost:8115 (`*.localhost` resolves to this machine;
  see [Scheduled tasks](#scheduled-tasks-and-the-store-url)).
- Admin: http://shop.localhost:8115/admin (user `admin@example.com`, password
  `admin12345`).
- Mailpit (every email nopCommerce sends): http://localhost:8025

Production
----------

```shell
cp .env.prod.example .env
# Required: NOP_URL, NOP_HOST, SITE_ADDRESS, DB_PASSWORD, NOP_ADMIN_EMAIL,
# NOP_ADMIN_PASSWORD.
# Recommended: the SMTP_* values (without SMTP_HOST no emails are sent).
docker compose up -d --build
```

- With `SITE_ADDRESS` set to the domain, Caddy gets a Let's Encrypt certificate
  and renews it automatically (certificates live in the `caddy_data` volume).
- Behind another TLS-terminating proxy, use `SITE_ADDRESS=:80`.
- Compose refuses to start while a required value is missing.
- The `backup` profile is enabled by default in the production template.
- Behind an existing Traefik (no host ports), use `overrides/traefik.yaml`
  (see [Overrides](#overrides)).

Services
--------

| Service   | Profile   | Role                                                              |
|-----------|-----------|-------------------------------------------------------------------|
| `db`      |           | PostgreSQL, data in the `db_data` volume.                         |
| `setup`   |           | One-shot job (`scripts/setup.sh`), runs on every `up`.            |
| `nop`     |           | nopCommerce (Kestrel, internal port 8080): store, admin, scheduled tasks. |
| `caddy`   |           | TLS and public address, the only published ports (80, 443).       |
| `backup`  | `backup`  | Database dump + App_Data + uploads on a schedule.                 |
| `mailpit` | `mailpit` | Development SMTP server that catches all mail.                    |

The application lives in the image. Volumes keep what changes:
`app_data` (`App_Data`: `appsettings.json`, `plugins.json`, the
DataProtection keys of login cookies, plus the image's App_Data files, which
`setup` refreshes when the image changes), `uploaded` (files uploaded in the
admin's editor) and `thumbs` (picture thumbnails, a cache). Product pictures
are stored in the database (nopCommerce's default). The database connection
comes from `DB_*` on every start (`scripts/entrypoint.sh`), not from
`appsettings.json`.

### What `setup` does

- Copies the image's App_Data files to the `app_data` volume when the image
  changes (keeping the installation's own files) and fixes the volumes'
  owners.
- Empty database: nopCommerce has no command-line installer, so `setup`
  starts it on `127.0.0.1:8080` inside the container and submits its
  installation form (`/install`) like a browser (antiforgery token included):
  PostgreSQL, the admin user, no sample data, country and culture
  `NOP_COUNTRY_CULTURE` (default `CL-es-CL`: Spanish language pack, CLP,
  Chile; the installer always adds English and USD too), no newsletter
  subscription. A value missing from the installer's country list stops
  `setup` before installing (the installer would silently use en-US). nopCommerce counts as installed once it has a
  connection string, so this start runs without
  `ConnectionStrings__ConnectionString` in its environment. Then starts it
  once more: nopCommerce installs its
  plugins on the start after the installer, as after the web installer. The
  `citext` extension nopCommerce needs is created first (its installer only
  does it when it creates the database itself).
- New image on an installed store: starts nopCommerce once, so it runs its
  database migrations (it does on startup) before anything else; a failed
  upgrade stops `setup`.
- `scripts/configure.sh` (SQL in nopCommerce's tables, while it's stopped:
  it caches settings):
  - once (then kept as edited in the admin): store name and title, the
    culture's language as the only published one (English, with a warning,
    when its pack couldn't be downloaded), the country's currency as the
    primary one (the others unpublished), time zone (`TIMEZONE`), prices
    including tax or not, two tax categories (`NOP_TAX_RATE` for the first)
    replacing the installer's Books, Apparel..., a single free shipping
    method, only the "Check / money order" payment method (the installer
    also enables PayPal, unconfigured, and "Manual", which stores card
    numbers). With a Spanish culture: "Afecto"/"Exento", "Despacho", the
    payment method renamed "Transferencia bancaria" with Spanish
    instructions, and Spanish email templates; other cultures get
    "Taxable"/"Exempt", "Shipping" and the installer's payment texts. For
    Chile (`CL-*`), optional postal codes. Tested with `CL-es-CL`,
    `US-en-US`, `ES-es-ES` and `DE-de-DE`.
  - every run: the store URL (`NOP_URL`) and the SMTP account (`SMTP_*`;
    the sender name defaults to `NOP_STORE_NAME`, the address to
    `noreply@example.com`).
    The app container gets the same variables, so a change recreates it after
    `setup`.

Common commands
---------------

```shell
docker compose ps                        # status: every service "healthy", setup "Exited (0)"
docker compose logs -f nop               # logs
docker compose exec db psql -U nopcommerce nopcommerce   # SQL shell
docker compose restart nop               # after changing settings in the database
docker compose down                      # stop, keep data
docker compose down -v                   # stop and DELETE all data
```

Scheduled tasks and the store URL
---------------------------------

nopCommerce runs its scheduled tasks (sending the email queue, keep alive,
exchange rates...) by POSTing to its own public URL
(`NOP_URL/scheduletask/runtask`). Inside a container that URL must reach
the site: `NOP_HOST` (the host name of `NOP_URL`) is resolved to the Docker
host (`host-gateway`), where Caddy or Traefik publishes it. That also works
on servers without hairpin NAT, and is why the development URL is
`http://shop.localhost:8115` (`localhost` itself can't be remapped).

- With local HTTPS (`SITE_ADDRESS=localhost` or a `*.localhost` name),
  Caddy's internal certificate isn't trusted inside the container and the
  tasks fail ("The SSL connection could not be established"): emails stay
  queued. Use plain HTTP in development; a real certificate in production.
- On Linux with `HTTP_BIND=127.0.0.1`, the Docker host's bridge address
  can't reach the published port; bind the ports to an address the
  containers can reach (production uses `0.0.0.0`).

Emails
------

nopCommerce queues emails and the "Send emails" task sends them every
minute through the store's email account, written from `SMTP_*` on every run
(`SMTP_SECURE`: `tls`, the default, = STARTTLS when the server offers it,
`ssl` = SMTPS, `none`). Without `SMTP_HOST` emails stay queued: SMTP is
recommended, not required. `SMTP_FROM` is also where store owner
notifications (new orders...) go. The installer creates that account with a limit of 0 emails
per run, so nothing would ever be sent; `setup` sets 50.

The language pack translates the store and the admin but not the email
templates: with a Spanish culture (and `NOP_EMAILS_SPANISH=true`), `setup`
writes Spanish subjects and bodies for the 46 active
templates (`config/nopcommerce/message-templates.es.json`) into the
templates themselves, once (with a single published language nopCommerce
ignores per-language template translations). Edit them in the admin
(Content management > Message templates). The file maps each template's
`Name` to its `subject` and `body`, generated from the database's English
templates with a map of English to Spanish phrases: for a new nopCommerce
version, compare it with the new database's `MessageTemplate` rows (names
and `%tokens%`) and translate what changed.

The installer asks nopcommerce.com for the language pack's download link,
sending the admin email (nopCommerce's web installer always does); use a
placeholder admin email and change it later if that matters. The call isn't
blocked on purpose: without that link es-CL gets ~860 text resources instead
of ~7.9k.

Integrations
------------

nopCommerce has no built-in back-office REST API or webhooks: integrations
are nopCommerce plugins (.NET), e.g. an `IConsumer<OrderPlacedEvent>`. A BillMySales integration would be such a
plugin, added to the image (`image/Dockerfile`) under `/app/Plugins`.

Backups
-------

With the `backup` profile, the `backup` service writes `<timestamp>-db.dump`
(`pg_dump` custom format) and `<timestamp>-files.tar.gz` (App_Data, with the
DataProtection keys, and uploads) to the `backups` volume (or
`./data/backups` with `overrides/local-dirs.yaml`) at start and then every
`BACKUP_INTERVAL_HOURS`, and deletes files older than `BACKUP_KEEP_DAYS`.
Files are readable by their owner only.

```shell
docker compose run --rm --no-deps backup now                  # back up now
docker compose run --rm --no-deps backup list                 # list timestamps
docker compose stop nop                                       # stop the app first
docker compose run --rm --no-deps backup restore <timestamp>  # database, App_Data, uploads
docker compose up -d
```

`--no-deps` keeps the commands from starting `setup` first (with damaged
data `setup` fails and the restore would never run); the database must be
running (`docker compose up -d db` if the stack is down). A restore replaces
the database with a fresh copy, so nothing created after the backup remains.

Upgrades
--------

Back up first, then change `NOP_VERSION` in `.env` and run
`docker compose up -d --build`: the image is rebuilt from the new official
release and `setup` starts nopCommerce once to run its migrations. Read
nopCommerce's release notes. Plugins that are new in a version are not
installed on an upgrade (only on a new install): install them in the admin
(Configuration > Local plugins) if needed. Rebuild regularly
(`docker compose build --pull`) for .NET and Alpine security fixes.

Overrides
---------

Optional compose files in `overrides/`, enabled with `COMPOSE_FILE` in `.env`
(several are combined with `:`). Each file documents its variables.

```shell
COMPOSE_FILE=compose.yaml:overrides/traefik.yaml:overrides/local-dirs.yaml
```

| File                        | Purpose                                                            |
|-----------------------------|--------------------------------------------------------------------|
| `overrides/traefik.yaml`    | Publish through an existing Traefik on a shared external network:  |
|                             | no host ports, Traefik terminates TLS (`TRAEFIK_HOST`, ...).       |
| `overrides/local-dirs.yaml` | Database, App_Data, uploads, thumbnails, Caddy and backups in      |
|                             | local directories (`DATA_DIR`, default `./data`).                  |

A local `compose.override.yaml` (gitignored) is also loaded automatically by
Docker Compose, for changes specific to one machine.

Configuration
-------------

Every variable is documented in `.env.prod.example`. Main groups:

- **Site and network**: `NOP_URL`, `NOP_HOST`, `SITE_ADDRESS`, `HTTP_BIND`,
  `HTTP_PORT`, `HTTPS_PORT`, `TIMEZONE` (the containers' time zone on every
  start; the store's time zone setting only on the first install).
- **Credentials**: `DB_PASSWORD`, `NOP_ADMIN_EMAIL`, `NOP_ADMIN_PASSWORD`
  (required; the admin values are only used by the installer).
- **Store** (first install only): `NOP_STORE_NAME` (also the default email
  sender name, on every run), `NOP_COUNTRY_CULTURE`, `NOP_TAX_RATE`,
  `NOP_PRICES_INCLUDE_TAX`, `NOP_EMAILS_SPANISH`.
- **Versions**: `NOP_VERSION`, `DOTNET_VERSION`, `POSTGRES_VERSION`,
  `CADDY_VERSION`, ...
- **Mail**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`,
  `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_FROM_NAME`.
- **Resources and logs**: `*_MEMORY_LIMIT` per service, `UPLOAD_MAX_SIZE`,
  `LOG_MAX_SIZE`, `LOG_MAX_FILE`.

Notes:

- Behind Caddy (and Traefik), nopCommerce trusts `X-Forwarded-For`/`-Proto`
  from private networks (`HostingConfig__UseProxy`, `KnownNetworks`): links
  and secure cookies follow the public `https://` address, and customers'
  IP addresses are the real ones.
- CLP amounts are shown without decimals (`$9.990`); the IVA included in
  prices is shown as "Impuestos" in carts and emails.
- The installer page (`/install`) is not published by Caddy (it only answers
  before the installation anyway).
- nopCommerce builds absolute picture URLs from the host of the request and
  caches them (every visitor got `http://localhost:8080/...` images after a
  healthcheck, and one request with a forged `Host` gave everyone that host's
  images). `setup` sets relative image URLs
  (`mediasettings.useabsoluteimagepath` = False) on every run, Caddy only
  passes on `NOP_HOST`, `NOP_EXTRA_HOSTS` and loopback names (other hosts:
  HTTP 400), and the healthchecks request `/robots.txt`, not a page. The
  sample slider's links, stored by the installer with setup's internal URL
  (`http://127.0.0.1:8080/`), are made relative.
- For maintainers of `scripts/configure.sh`: enum settings store names, not
  ids (`taxsettings.taxdisplaytype` = `IncludingTax`), and the store's
  `HomepageTitle` is set empty (otherwise the home page title reads
  "Tienda. Tienda").
- nopCommerce's license (nopCommerce Public License 4.0) requires the
  "Powered by nopCommerce" link in the store footer unless you buy its
  removal.
- From inside the container, the host machine is reachable as
  `host.docker.internal`.

Security
--------

- No default secrets: compose fails if the required passwords are missing.
  The development template uses public values; never use it on a server.
- nopCommerce runs as an unprivileged user; only Caddy (and Mailpit in
  development) publishes ports; nopCommerce and PostgreSQL are internal.
  `HTTP_BIND` defaults to `127.0.0.1`.
- Only one payment method is enabled (no card data stored by the store).
- Host header: see the notes above (forged hosts are refused by Caddy;
  emails use the store URL, not the request's host).
- Not included: a web application firewall or off-site backup copies.

Validation
----------

What was checked for this stack (2026-09-25):

- Clean start (`down -v` + `up -d --build`, image built) in about a minute:
  every service `healthy`, `setup` `Exited (0)`; a second run makes no
  changes; a database password with `;` and `"` works.
- Store in Spanish (`lang="es"`, title, all CSS/JS and images, including
  relative picture URLs; a forged `Host` gets HTTP 400), admin login
  (form with antiforgery token), dashboard and its assets; a product created
  through the admin form; guest one-page checkout (billing, "Despacho",
  "Transferencia bancaria"): 2 × $9.990 = $19.980 with $3.190 IVA
  included, order in CLP.
- Emails through SMTP to Mailpit in Spanish (order receipt to the customer,
  new order to the store), with links to `NOP_URL`; scheduled tasks
  running through `NOP_HOST`.
- Other cultures (2026-09-26, image rebuilt with `--no-cache --pull`, each
  on a new database): `US-en-US` (English, USD, "Taxable"/"Exempt"),
  `ES-es-ES` (Spanish texts and emails, EUR, postal code required),
  `DE-de-DE` (German pack, EUR, English names); `DE-de-DE` without access
  to nopcommerce.com falls back to English with a warning; `XX-xx-XX` stops
  `setup` before installing, and the next `up` with a valid value installs.
- Backup and restore (an order created after the backup is gone; uploads
  and DataProtection keys back: an admin session from before the backup
  still works).
- Upgrade 4.80.9 → 4.90.8 with data: migrations run by `setup`, orders kept,
  a new order afterwards. The upgraded schema matches a fresh 4.90.8 install
  except for upstream details: two column defaults, an index order, and the
  tables of plugins new in 4.90 (not installed on upgrades).
- HTTPS with `SITE_ADDRESS=shop.localhost` (links and secure cookies on
  `https://`; scheduled tasks fail on Caddy's internal certificate, see
  above); URL change and back; overrides: Traefik v3.6 routing with no host
  ports (client IP kept, also in nopCommerce), local directories (fresh
  install).
- Not tested: issuing a real Let's Encrypt certificate (needs a public
  domain), real payment providers, a real SMTP provider.

Testing
-------

- The admin product form POST needs every field of the form (as a browser
  sends it; multi-selects only their selected options), antiforgery token
  included.
- Guest one-page checkout, after adding a product to the cart:
  `/checkout/OpcSaveBilling/`, `OpcSaveShippingMethod` (value
  `Despacho___Shipping.FixedByWeightByTotal`), `OpcSavePaymentMethod`,
  `OpcSavePaymentInfo`, `OpcConfirmOrder`.

Resource usage
--------------

Idle, after a few requests: nopCommerce ~400 MiB, PostgreSQL ~50 MiB, Caddy
~13 MiB (about 470 MiB in total). Image ~660 MB.

License
-------

[MIT](LICENSE) (the stack; nopCommerce itself is under the nopCommerce
Public License 4.0).
