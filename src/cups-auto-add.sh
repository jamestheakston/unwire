#!/usr/bin/env bash
#
# Unwire - cups-auto-add.sh
# Detects connected USB printers, configures CUPS queues for them,
# generates AirPrint Avahi service files, and refreshes the dashboard.
#
# Triggered by:
#   - the udev rule at /etc/udev/rules.d/99-cups-autorun.rules on USB
#     printer-class insertion
#   - install.sh during initial setup, to catch printers already plugged in
#
set -uo pipefail

readonly AVAHI_SERVICES_DIR="/etc/avahi/services"
readonly WEBPAGE_SCRIPT="/usr/local/bin/update-printer-webpage.sh"
readonly LOG_TAG="unwire-auto-add"
readonly LOCK_FILE="/var/run/unwire-cups-auto-add.lock"

log() {
    logger -t "${LOG_TAG}" "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Simple lock to avoid overlapping runs if multiple udev events fire in
# quick succession (e.g. a multi-function USB printer enumerates as
# several interfaces).
# ---------------------------------------------------------------------------
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "Another instance is already running. Exiting."
    exit 0
fi

mkdir -p "${AVAHI_SERVICES_DIR}"

# ---------------------------------------------------------------------------
# sanitize_name <string>
# Produces a filesystem/CUPS-safe identifier: alnum and underscores only.
# ---------------------------------------------------------------------------
sanitize_name() {
    local input="$1"
    echo "${input}" \
        | sed -E 's/[^A-Za-z0-9]+/_/g' \
        | sed -E 's/_+/_/g' \
        | sed -E 's/^_//; s/_$//'
}

# ---------------------------------------------------------------------------
# get_existing_queues
# Returns a newline-separated list of existing CUPS queue names.
# ---------------------------------------------------------------------------
get_existing_queues() {
    lpstat -p 2>/dev/null | awk '/^printer/ {print $2}'
}

EXISTING_QUEUES="$(get_existing_queues)"

queue_exists() {
    local queue_name="$1"
    echo "${EXISTING_QUEUES}" | grep -qx "${queue_name}"
}

# ---------------------------------------------------------------------------
# Track which Unwire-managed queues are seen as physically present during
# this run, so we can detect and clean up printers that have been
# unplugged since the last scan (this script runs continuously via a
# systemd timer as well as on udev events, so it must be idempotent and
# safe to re-run every few seconds).
# ---------------------------------------------------------------------------
declare -A SEEN_QUEUES=()

# ---------------------------------------------------------------------------
# Parse `lpinfo -v` for USB device URIs.
# Typical line:
#   direct usb://HP/DeskJet%203630%20series?serial=ABC123
# ---------------------------------------------------------------------------
USB_URIS="$(lpinfo -v 2>/dev/null | awk '/usb:\/\//{print $2}')"

CHANGED=0

if [[ -z "${USB_URIS}" ]]; then
    log "No USB printers currently detected."
fi

while IFS= read -r uri; do
    [[ -z "${uri}" ]] && continue

    # ---------------------------------------------------------------------
    # Extract a friendly printer name from the URI.
    # usb://Manufacturer/Model%20Name?serial=XYZ
    # ---------------------------------------------------------------------
    raw_path="${uri#usb://}"          # Manufacturer/Model%20Name?serial=XYZ
    raw_path="${raw_path%%\?*}"       # Manufacturer/Model%20Name
    manufacturer="${raw_path%%/*}"
    model_encoded="${raw_path#*/}"

    # Decode %XX URL-encoding.
    model_decoded="$(printf '%b' "${model_encoded//%/\\x}")"
    manufacturer_decoded="$(printf '%b' "${manufacturer//%/\\x}")"

    friendly_name="${manufacturer_decoded} ${model_decoded}"
    friendly_name="$(echo "${friendly_name}" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //; s/ $//')"

    if [[ -z "${friendly_name}" ]]; then
        friendly_name="USB Printer"
    fi

    queue_name="$(sanitize_name "${friendly_name}")"
    description="${friendly_name} - Unwire"

    SEEN_QUEUES["${queue_name}"]=1

    if queue_exists "${queue_name}"; then
        log "Queue '${queue_name}' already present and connected."
        # Queue may have been disabled by a previous cleanup pass (e.g. if
        # it was briefly unplugged); bring it back online now that it's
        # physically present again.
        lpadmin -p "${queue_name}" -D "${description}" >/dev/null 2>&1
        lpadmin -p "${queue_name}" -o printer-is-shared=true >/dev/null 2>&1
        cupsenable "${queue_name}" >/dev/null 2>&1
        cupsaccept "${queue_name}" >/dev/null 2>&1
    else
        log "Configuring new printer: ${friendly_name} (uri: ${uri})"

        # -------------------------------------------------------------
        # Determine the best driver/PPD, in priority order:
        #   1. IPP Everywhere (driverless)
        #   2. A matching driver found via `lpinfo -m`
        #   3. gutenprint generic fallback
        #   4. raw queue as last resort
        # -------------------------------------------------------------
        ADD_SUCCESS=0

        if lpadmin -p "${queue_name}" -E -v "${uri}" -m "everywhere" \
            >/dev/null 2>&1; then
            ADD_SUCCESS=1
            log "Configured '${queue_name}' using IPP Everywhere."
        fi

        if [[ "${ADD_SUCCESS}" -eq 0 ]]; then
            MATCHED_DRIVER="$(lpinfo -m 2>/dev/null \
                | grep -i -F "$(echo "${model_decoded}" | awk '{print $1}')" \
                | head -n 1 \
                | awk '{print $1}')"

            if [[ -n "${MATCHED_DRIVER}" ]]; then
                if lpadmin -p "${queue_name}" -E -v "${uri}" -m "${MATCHED_DRIVER}" \
                    >/dev/null 2>&1; then
                    ADD_SUCCESS=1
                    log "Configured '${queue_name}' using driver '${MATCHED_DRIVER}'."
                fi
            fi
        fi

        if [[ "${ADD_SUCCESS}" -eq 0 ]]; then
            if lpadmin -p "${queue_name}" -E -v "${uri}" -m "gutenprint.5.3://generic/expert" \
                >/dev/null 2>&1; then
                ADD_SUCCESS=1
                log "Configured '${queue_name}' using gutenprint fallback."
            fi
        fi

        if [[ "${ADD_SUCCESS}" -eq 0 ]]; then
            lpadmin -p "${queue_name}" -E -v "${uri}" -m "raw" >/dev/null 2>&1
            ADD_SUCCESS=1
            log "Configured '${queue_name}' as a raw queue (no matching driver found)."
        fi

        # Set description and sharing regardless of which driver path succeeded.
        lpadmin -p "${queue_name}" -D "${description}" >/dev/null 2>&1
        lpadmin -p "${queue_name}" -o printer-is-shared=true >/dev/null 2>&1
        cupsenable "${queue_name}" >/dev/null 2>&1
        cupsaccept "${queue_name}" >/dev/null 2>&1

        CHANGED=1
    fi

    # -----------------------------------------------------------------
    # Generate (or refresh) the Avahi AirPrint service file for this
    # queue, regardless of whether the CUPS queue was just created or
    # already existed, so TXT records stay in sync with the name.
    # -----------------------------------------------------------------
    service_file="${AVAHI_SERVICES_DIR}/airprint-${queue_name}.service"

    cat > "${service_file}" <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">${description}</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/${queue_name}</txt-record>
    <txt-record>ty=${description}</txt-record>
    <txt-record>adminurl=http://admin.unwire.local/printers/${queue_name}</txt-record>
    <txt-record>note=Unwire AirPrint Hub</txt-record>
    <txt-record>priority=0</txt-record>
    <txt-record>product=(${description})</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-type=0x800003</txt-record>
    <txt-record>pdl=application/pdf,image/urf</txt-record>
    <txt-record>URF=W8,SRGB24,CP1,RS300-600</txt-record>
    <txt-record>Color=T</txt-record>
    <txt-record>Duplex=F</txt-record>
    <txt-record>usb_MFG=${manufacturer_decoded}</txt-record>
    <txt-record>usb_MDL=${model_decoded}</txt-record>
  </service>
</service-group>
EOF

    chmod 644 "${service_file}"

done <<< "${USB_URIS}"

# ---------------------------------------------------------------------------
# Cleanup pass: any Unwire-managed printer (identified by having an
# airprint-*.service file) that was NOT seen as physically connected in
# this scan gets disabled in CUPS and its AirPrint broadcast removed, so
# stale/unplugged printers don't linger as "Online" or keep advertising
# over mDNS. This is what makes it safe to run this script on a recurring
# timer in addition to udev events.
# ---------------------------------------------------------------------------
if compgen -G "${AVAHI_SERVICES_DIR}/airprint-*.service" > /dev/null 2>&1; then
    for service_file in "${AVAHI_SERVICES_DIR}"/airprint-*.service; do
        base="$(basename "${service_file}")"          # airprint-<queue>.service
        managed_queue="${base#airprint-}"
        managed_queue="${managed_queue%.service}"

        if [[ -z "${SEEN_QUEUES[${managed_queue}]:-}" ]]; then
            log "Printer '${managed_queue}' no longer detected. Marking offline."
            cupsdisable -r "Printer disconnected (Unwire)" "${managed_queue}" >/dev/null 2>&1
            rm -f "${service_file}"
            CHANGED=1
        fi
    done
fi

# ---------------------------------------------------------------------------
# Reload Avahi so new/updated service files are broadcast immediately.
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    systemctl reload avahi-daemon >/dev/null 2>&1 \
        || systemctl restart avahi-daemon >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# Refresh the dashboard to reflect current printer state.
# ---------------------------------------------------------------------------
if [[ -x "${WEBPAGE_SCRIPT}" ]]; then
    "${WEBPAGE_SCRIPT}"
fi

log "cups-auto-add run complete. changed=${CHANGED}"
exit 0