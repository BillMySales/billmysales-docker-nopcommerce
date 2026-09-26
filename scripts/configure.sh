#!/bin/sh
# shellcheck disable=SC2153 # variables set by compose
# Store settings of nopCommerce, written in its database (nopCommerce has no
# CLI; it keeps its settings in the "Setting" table and a few entities).
# Run by setup.sh while nopCommerce is stopped (it caches settings): the app
# container gets the same variables, so a change also recreates it.
#
# - Once (marker setting docker_stack.initialized), adapting the installer's
#   defaults (the installer creates English and USD, plus the language,
#   currency and country of NOP_COUNTRY_CULTURE; the language's pack is
#   downloaded from nopcommerce.com): store name and titles, the culture's
#   language as the only published one (English when its pack couldn't be
#   installed), the country's currency as the primary one (the others
#   unpublished), time zone, prices including tax or not, tax categories
#   "Afecto" (NOP_TAX_RATE) and "Exento" instead of the installer's (Books,
#   Apparel...), only the "Check / money order" payment method (the
#   installer also enables PayPal, unconfigured, and "Manual", which stores
#   card numbers), one free shipping method. With a Spanish culture, also:
#   Spanish names ("Despacho", the payment method as "Transferencia
#   bancaria") and email templates (config/nopcommerce); English names
#   ("Taxable", "Exempt", "Shipping") otherwise. For Chile (CL), postal
#   codes optional. Later changes in the admin are kept.
# - Every run: the store URL (NOP_URL) and the SMTP account (SMTP_*; also
#   emails per run of the send task, 0 on a fresh install = none sent);
#   relative image URLs (nopCommerce builds absolute ones from the request's
#   Host and caches them: a request with another Host, even the internal
#   healthcheck's, gave every visitor its image URLs); the sample slider's
#   links, which the installer stores with setup's internal URL, made
#   relative.
set -eu

sql_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# Upsert of a global setting (names are lowercase, like nopCommerce's).
set_setting() {
    name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    value="$(sql_quote "$2")"
    cat <<SQL
UPDATE "Setting" SET "Value" = ${value} WHERE "Name" = '${name}' AND "StoreId" = 0;
INSERT INTO "Setting" ("Name", "Value", "StoreId")
    SELECT '${name}', ${value}, 0
    WHERE NOT EXISTS (SELECT 1 FROM "Setting" WHERE "Name" = '${name}' AND "StoreId" = 0);
SQL
}

# Upsert of a language's string resource (names are lowercase).
set_resource() {
    name="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
    value="$(sql_quote "$3")"
    cat <<SQL
UPDATE "LocaleStringResource" SET "ResourceValue" = ${value} WHERE "LanguageId" = $1 AND "ResourceName" = '${name}';
INSERT INTO "LocaleStringResource" ("LanguageId", "ResourceName", "ResourceValue")
    SELECT $1, '${name}', ${value}
    WHERE NOT EXISTS (SELECT 1 FROM "LocaleStringResource" WHERE "LanguageId" = $1 AND "ResourceName" = '${name}');
SQL
}

query() { psql -XAtqc "$1"; }

sql=/tmp/configure.sql
echo "BEGIN;" > "${sql}"

initialized="$(query "SELECT count(*) FROM \"Setting\" WHERE \"Name\" = 'docker_stack.initialized'")"
if [ "${initialized}" = 0 ]; then
    # NOP_COUNTRY_CULTURE: country-culture, e.g. CL-es-CL (checked by setup.sh).
    country="${NOP_COUNTRY_CULTURE%%-*}"
    culture="${NOP_COUNTRY_CULTURE#*-}"
    # Separate assignments: with `set -e`, a failing query stops here.
    # The culture's language if its pack was installed (thousands of
    # resources; without it the store would show resource names), else English.
    lang="$(query "SELECT l.\"Id\" FROM \"Language\" l WHERE l.\"LanguageCulture\" IN ($(sql_quote "${culture}"), 'en-US')
        ORDER BY (l.\"LanguageCulture\" = $(sql_quote "${culture}")
            AND (SELECT count(*) FROM \"LocaleStringResource\" r WHERE r.\"LanguageId\" = l.\"Id\") > 1000) DESC, l.\"Id\" LIMIT 1")"
    lang_culture="$(query "SELECT \"LanguageCulture\" FROM \"Language\" WHERE \"Id\" = ${lang:-0}")"
    # The installer publishes the country's currency first (DisplayOrder 0).
    currency="$(query "SELECT \"Id\" FROM \"Currency\" WHERE \"Published\" ORDER BY \"DisplayOrder\", \"Id\" LIMIT 1")"
    currency_code="$(query "SELECT \"CurrencyCode\" FROM \"Currency\" WHERE \"Id\" = ${currency:-0}")"
    if [ -z "${lang_culture}" ] || [ -z "${currency_code}" ]; then
        echo "The installer created no language or currency" >&2
        exit 1
    fi
    if [ "${lang_culture}" != "${culture}" ]; then
        echo "WARNING: no language pack for ${culture} was installed (nopcommerce.com unreachable or" \
            "translation incomplete): the store uses ${lang_culture}" >&2
    fi
    echo "Initial store settings (${NOP_STORE_NAME}, ${lang_culture}, ${currency_code}, tax ${NOP_TAX_RATE:-0}%)"
    case "${lang_culture}" in
        es-*) spanish=true taxable=Afecto exempt=Exento shipping=Despacho ;;
        *) spanish=false taxable=Taxable exempt=Exempt shipping=Shipping ;;
    esac
    include_tax=False tax_display=ExcludingTax
    if [ "${NOP_PRICES_INCLUDE_TAX}" = true ]; then
        include_tax=True tax_display=IncludingTax
    fi
    store_name="$(sql_quote "${NOP_STORE_NAME}")"
    cat >> "${sql}" <<SQL
UPDATE "Store" SET "Name" = ${store_name}, "CompanyName" = ${store_name}, "DefaultLanguageId" = ${lang},
    "DefaultTitle" = ${store_name}, "HomepageTitle" = '', "HomepageDescription" = '',
    "DefaultMetaDescription" = '', "DefaultMetaKeywords" = '';
UPDATE "Language" SET "Published" = ("Id" = ${lang}), "DisplayOrder" = CASE WHEN "Id" = ${lang} THEN 1 ELSE 2 END;
UPDATE "Currency" SET "Published" = ("Id" = ${currency}), "Rate" = 1, "DisplayOrder" = CASE WHEN "Id" = ${currency} THEN 1 ELSE 2 END;
-- Tax categories: the installer's (Books, Electronics...) replaced.
UPDATE "TaxCategory" SET "Name" = '${taxable}', "DisplayOrder" = 1 WHERE "Id" = 1;
UPDATE "TaxCategory" SET "Name" = '${exempt}', "DisplayOrder" = 2 WHERE "Id" = 2;
DELETE FROM "TaxCategory" WHERE "Id" > 2;
-- Shipping: one free method.
UPDATE "ShippingMethod" SET "Name" = '${shipping}', "Description" = '', "DisplayOrder" = 1 WHERE "Id" = 1;
DELETE FROM "ShippingMethod" WHERE "Id" > 1;
SQL
    {
        set_setting localizationsettings.defaultadminlanguageid "${lang}"
        set_setting currencysettings.primarystorecurrencyid "${currency}"
        set_setting currencysettings.primaryexchangeratecurrencyid "${currency}"
        set_setting datetimesettings.defaultstoretimezoneid "${TZ}"
        set_setting taxsettings.pricesincludetax "${include_tax}"
        set_setting taxsettings.taxdisplaytype "${tax_display}"
        set_setting taxsettings.defaulttaxcategoryid 1
        set_setting tax.taxprovider.fixedorbycountrystatezip.taxcategoryid1 "${NOP_TAX_RATE:-0}"
        set_setting tax.taxprovider.fixedorbycountrystatezip.taxcategoryid2 0
        set_setting paymentsettings.activepaymentmethodsystemnames Payments.CheckMoneyOrder
        set_setting shippingratecomputationmethod.fixedbyweightbytotal.rate.shippingmethodid1 0
        if [ "${spanish}" = true ]; then
            # "Check / money order" used as a bank transfer.
            set_resource "${lang}" plugins.friendlyname.payments.checkmoneyorder "Transferencia bancaria"
            set_resource "${lang}" plugins.payment.checkmoneyorder.paymentmethoddescription "Pago por transferencia bancaria"
            set_setting checkmoneyorderpaymentsettings.descriptiontext "<p>Paga por transferencia bancaria: te enviaremos los datos de la cuenta por correo y despacharemos tu pedido cuando recibamos el pago.</p><p>(Puedes editar este texto en Configuración &gt; Pagos &gt; Transferencia bancaria.)</p>"
        fi
        if [ "${country}" = CL ]; then
            # Postal codes are optional in Chile.
            set_setting addresssettings.zippostalcoderequired False
        fi
        if [ "${spanish}" = true ] && [ "${NOP_EMAILS_SPANISH:-true}" = true ]; then
            # Spanish subjects and bodies of the email templates (the language
            # pack only translates the site). Written into the templates
            # themselves: with a single published language nopCommerce
            # ignores localized values and uses the template's own.
            cat <<SQL
\\set templates \`cat /usr/local/share/stack/config/nopcommerce/message-templates.es.json\`
UPDATE "MessageTemplate" m
    SET "Subject" = t.value->>'subject', "Body" = t.value->>'body'
    FROM json_each(:'templates'::json) t
    WHERE m."Name" = t.key;
SQL
        fi
        # Marker last: a failed run is repeated.
        set_setting docker_stack.initialized "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "${sql}"
fi

# Every run: store URL and SMTP.
url="${NOP_URL%/}/"
ssl=false
case "${url}" in https://*) ssl=true ;; esac
account="$(query "SELECT \"Value\" FROM \"Setting\" WHERE \"Name\" = 'emailaccountsettings.defaultemailaccountid' AND \"StoreId\" = 0")"
smtp_ssl=false
if [ "$(echo "${SMTP_SECURE:-tls}" | tr '[:upper:]' '[:lower:]')" = ssl ]; then
    smtp_ssl=true
fi
auth=0
if [ -n "${SMTP_USER:-}" ]; then
    auth=10
fi
cat >> "${sql}" <<SQL
UPDATE "Store" SET "Url" = $(sql_quote "${url}"), "SslEnabled" = ${ssl}
    WHERE "Id" = (SELECT min("Id") FROM "Store");
$(set_setting mediasettings.useabsoluteimagepath False)
UPDATE "Setting" SET "Value" = replace("Value", '"LinkUrl":"http://127.0.0.1:8080/', '"LinkUrl":"/')
    WHERE "Name" = 'swipersettings.slides' AND "Value" LIKE '%"LinkUrl":"http://127.0.0.1:8080/%';
UPDATE "EmailAccount" SET
    "Email" = $(sql_quote "${SMTP_FROM:-noreply@example.com}"),
    "DisplayName" = $(sql_quote "${SMTP_FROM_NAME:-${NOP_STORE_NAME}}"),
    "Host" = $(sql_quote "${SMTP_HOST:-}"),
    "Port" = ${SMTP_PORT:-587},
    "Username" = $(sql_quote "${SMTP_USER:-}"),
    "Password" = $(sql_quote "${SMTP_PASSWORD:-}"),
    "EnableSsl" = ${smtp_ssl},
    "EmailAuthenticationMethodId" = ${auth},
    -- The installer's account has 0: its send task takes that many emails
    -- per run, so nothing would ever be sent.
    "MaxNumberOfEmails" = CASE WHEN "MaxNumberOfEmails" < 1 THEN 50 ELSE "MaxNumberOfEmails" END
    WHERE "Id" = ${account:-1};
COMMIT;
SQL

psql -XAq -v ON_ERROR_STOP=1 -f "${sql}"
rm -f "${sql}"
echo "Store settings OK (${url})"
