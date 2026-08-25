#!/usr/bin/env bash
#
# Unwire - Zero-configuration AirPrint hub for Raspberry Pi
# install.sh (single-file edition)
#
# Usage: curl -sSL <URL> | sudo bash
#
# This single file contains the installer plus every helper script,
# udev rule, and systemd unit Unwire needs. Nothing else needs to be
# downloaded separately.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: must be root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Unwire must be run as root. Try: curl -sSL <URL> | sudo bash"
    exit 1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly UNWIRE_HOSTNAME="unwire"
readonly BIN_DIR="/usr/local/bin"
readonly UDEV_RULE_PATH="/etc/udev/rules.d/99-cups-autorun.rules"
readonly AVAHI_SERVICES_DIR="/etc/avahi/services"
readonly WEBROOT="/var/www/html"
readonly CUPSD_CONF="/etc/cups/cupsd.conf"
readonly NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly LOG_FILE="/var/log/unwire-install.log"
readonly TOTAL_STEPS=9

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
step() {
    echo "[$1/${TOTAL_STEPS}] $2..."
}

run_quiet() {
    "$@" >>"${LOG_FILE}" 2>&1
}

: > "${LOG_FILE}"

echo "=============================================="
echo " Unwire - AirPrint Hub Installer"
echo "=============================================="

# ---------------------------------------------------------------------------
# [1/9] Install packages
# ---------------------------------------------------------------------------
step 1 "Installing packages"
export DEBIAN_FRONTEND=noninteractive
run_quiet apt-get update -y
run_quiet apt-get install -y \
    cups \
    avahi-daemon \
    avahi-utils \
    printer-driver-gutenprint \
    hplip \
    brlaser \
    system-config-printer \
    nginx

# ---------------------------------------------------------------------------
# [2/9] Hostname
# ---------------------------------------------------------------------------
step 2 "Configuring hostname"
CURRENT_HOSTNAME="$(hostname)"
if [[ "${CURRENT_HOSTNAME}" != "${UNWIRE_HOSTNAME}" ]]; then
    run_quiet hostnamectl set-hostname "${UNWIRE_HOSTNAME}"
fi

if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${UNWIRE_HOSTNAME}/" /etc/hosts
else
    echo -e "127.0.1.1\t${UNWIRE_HOSTNAME}" >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# [3/9] CUPS configuration
# ---------------------------------------------------------------------------
step 3 "Configuring CUPS"
cp "${CUPSD_CONF}" "${CUPSD_CONF}.unwire.bak" 2>/dev/null || true

cat > "${CUPSD_CONF}" <<'CUPSD_EOF'
LogLevel warn
PageLogFormat

MaxLogSize 0

SystemGroup lpadmin

Listen *:631
Listen /run/cups/cups.sock

Browsing On
BrowseLocalProtocols dnssd

DefaultAuthType Basic
WebInterface Yes

ServerAlias *

<Location />
  Order allow,deny
  Allow all
</Location>

<Location /admin>
  Order allow,deny
  Allow all
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

<Location /admin/log>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
CUPSD_EOF

run_quiet cupsctl --remote-admin --remote-any --share-printers

# ---------------------------------------------------------------------------
# [4/9] Nginx configuration
# ---------------------------------------------------------------------------
step 4 "Configuring Nginx"
mkdir -p "${WEBROOT}"

cat > "${NGINX_SITES_AVAILABLE}/unwire.conf" <<NGINX_EOF
server {
    listen 80;
    server_name unwire.local;

    root ${WEBROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 80;
    server_name admin.unwire.local;

    location / {
        proxy_pass http://127.0.0.1:631;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
NGINX_EOF

rm -f "${NGINX_SITES_ENABLED}/default"
ln -sf "${NGINX_SITES_AVAILABLE}/unwire.conf" "${NGINX_SITES_ENABLED}/unwire.conf"

# ---------------------------------------------------------------------------
# [5/9] Install helper scripts
# ---------------------------------------------------------------------------
step 5 "Installing helper scripts"
mkdir -p "${BIN_DIR}"

cat > "${BIN_DIR}/update-printer-webpage.sh" <<'WEBPAGE_SCRIPT_EOF'
#!/usr/bin/env bash
#
# Unwire - update-printer-webpage.sh
# Regenerates the web status dashboard at /var/www/html/index.html
# based on the currently configured CUPS print queues.
#
set -uo pipefail

readonly WEBROOT="/var/www/html"
readonly OUTPUT_FILE="${WEBROOT}/index.html"
readonly LOG_TAG="unwire-webpage"

mkdir -p "${WEBROOT}"

log() {
    logger -t "${LOG_TAG}" "$1" 2>/dev/null || true
}

declare -a PRINTER_NAMES=()
declare -a PRINTER_STATES=()

if command -v lpstat >/dev/null 2>&1; then
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        queue_name="$(echo "${line}" | awk '{print $2}')"
        [[ -z "${queue_name}" ]] && continue

        if echo "${line}" | grep -qi "disabled"; then
            state="Offline"
        else
            state="Online"
        fi

        description="$(lpstat -l -p "${queue_name}" 2>/dev/null \
            | grep -i "Description:" \
            | sed -E 's/^[[:space:]]*Description:[[:space:]]*//')"

        if [[ -n "${description}" ]]; then
            display_name="${description}"
        else
            display_name="$(echo "${queue_name}" | sed 's/_/ /g') - Unwire"
        fi

        PRINTER_NAMES+=("${display_name}")
        PRINTER_STATES+=("${state}")
    done < <(lpstat -p 2>/dev/null | grep -E '^printer ')
fi

build_printer_cards() {
    if [[ ${#PRINTER_NAMES[@]} -eq 0 ]]; then
        cat <<'EOF'
        <div class="empty-state">
          <p>No printers detected yet.</p>
          <p class="empty-sub">Plug in a USB printer and it will appear here automatically.</p>
        </div>
EOF
        return
    fi

    local i
    for i in "${!PRINTER_NAMES[@]}"; do
        local name="${PRINTER_NAMES[$i]}"
        local state="${PRINTER_STATES[$i]}"
        local badge_class="badge-online"
        [[ "${state}" != "Online" ]] && badge_class="badge-offline"

        cat <<EOF
        <div class="printer-card">
          <div class="printer-info">
            <div class="printer-icon">&#128424;</div>
            <div class="printer-name">${name}</div>
          </div>
          <span class="badge ${badge_class}">${state}</span>
        </div>
EOF
    done
}

PRINTER_CARDS_HTML="$(build_printer_cards)"
GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

cat > "${OUTPUT_FILE}" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Unwire - AirPrint Hub</title>
<style>
  :root {
    --bg: #f4f5f7;
    --card-bg: #ffffff;
    --text-primary: #1a1d21;
    --text-secondary: #6b7280;
    --border: #e5e7eb;
    --accent: #2563eb;
    --green: #16a34a;
    --green-bg: #dcfce7;
    --gray-bg: #f3f4f6;
    --gray-text: #6b7280;
    --shadow: 0 1px 3px rgba(0, 0, 0, 0.06), 0 1px 2px rgba(0, 0, 0, 0.04);
  }

  * {
    box-sizing: border-box;
  }

  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
      "Helvetica Neue", Arial, sans-serif;
    background-color: var(--bg);
    color: var(--text-primary);
    display: flex;
    flex-direction: column;
    min-height: 100vh;
  }

  .container {
    max-width: 720px;
    width: 100%;
    margin: 0 auto;
    padding: 48px 24px;
    flex: 1;
  }

  header {
    text-align: center;
    margin-bottom: 32px;
  }

  .logo {
    font-size: 40px;
    margin-bottom: 8px;
  }

  h1 {
    font-size: 28px;
    font-weight: 700;
    margin: 0 0 4px 0;
    letter-spacing: -0.02em;
  }

  .subtitle {
    color: var(--text-secondary);
    font-size: 15px;
    margin: 0;
  }

  .card {
    background: var(--card-bg);
    border-radius: 12px;
    border: 1px solid var(--border);
    box-shadow: var(--shadow);
    padding: 24px;
    margin-bottom: 20px;
  }

  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }

  .card-title {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-primary);
    margin: 0;
  }

  .card-meta {
    font-size: 12px;
    color: var(--text-secondary);
  }

  .printer-card {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 16px;
    border-radius: 8px;
    background: var(--gray-bg);
    margin-bottom: 10px;
  }

  .printer-card:last-child {
    margin-bottom: 0;
  }

  .printer-info {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .printer-icon {
    font-size: 20px;
  }

  .printer-name {
    font-size: 14px;
    font-weight: 500;
    color: var(--text-primary);
  }

  .badge {
    font-size: 12px;
    font-weight: 600;
    padding: 4px 10px;
    border-radius: 999px;
  }

  .badge-online {
    background: var(--green-bg);
    color: var(--green);
  }

  .badge-offline {
    background: #fee2e2;
    color: #dc2626;
  }

  .empty-state {
    text-align: center;
    padding: 24px 0;
  }

  .empty-state p {
    margin: 0 0 4px 0;
    color: var(--text-secondary);
  }

  .empty-sub {
    font-size: 13px;
  }

  .admin-link {
    display: block;
    text-align: center;
    background: var(--accent);
    color: #fff;
    text-decoration: none;
    font-weight: 600;
    font-size: 14px;
    padding: 14px;
    border-radius: 8px;
    transition: opacity 0.15s ease;
  }

  .admin-link:hover {
    opacity: 0.9;
  }

  footer {
    text-align: center;
    padding: 24px;
    color: var(--text-secondary);
    font-size: 13px;
  }
</style>
</head>
<body>
  <div class="container">
    <header>
      <div class="logo">&#128225;</div>
      <h1>Unwire</h1>
      <p class="subtitle">Wireless AirPrint hub status</p>
    </header>

    <div class="card">
      <div class="card-header">
        <p class="card-title">Connected Printers</p>
        <span class="card-meta">Updated ${GENERATED_AT}</span>
      </div>
${PRINTER_CARDS_HTML}
    </div>

    <div class="card">
      <a class="admin-link" href="http://admin.unwire.local">Open CUPS Administration &rarr;</a>
    </div>
  </div>

  <footer>Powered by open-source software</footer>
</body>
</html>
HTML

chmod 644 "${OUTPUT_FILE}"
log "Dashboard regenerated with ${#PRINTER_NAMES[@]} printer(s)."

exit 0
WEBPAGE_SCRIPT_EOF

cat > "${BIN_DIR}/cups-auto-add.sh" <<'AUTOADD_SCRIPT_EOF'
#!/usr/bin/env bash
#
# Unwire - cups-auto-add.sh
# Detects connected USB printers, configures CUPS queues for them,
# generates AirPrint Avahi service files, and refreshes the dashboard.
#
# Triggered by:
#   - the udev rule at /etc/udev/rules.d/99-cups-autorun.rules on USB
#     printer-class insertion (near-instant detection)
#   - the unwire-scan.timer systemd timer, every 30 seconds (continuous
#     backstop in case a udev event is missed, and to detect unplugged
#     printers so they can be marked offline)
#   - install.sh during initial setup, to catch printers already plugged in
#
# This script is idempotent and safe to run repeatedly/concurrently.
#
set -uo pipefail

readonly AVAHI_SERVICES_DIR="/etc/avahi/services"
readonly WEBPAGE_SCRIPT="/usr/local/bin/update-printer-webpage.sh"
readonly LOG_TAG="unwire-auto-add"
readonly LOCK_FILE="/var/run/unwire-cups-auto-add.lock"

log() {
    logger -t "${LOG_TAG}" "$1" 2>/dev/null || true
}

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "Another instance is already running. Exiting."
    exit 0
fi

mkdir -p "${AVAHI_SERVICES_DIR}"

sanitize_name() {
    local input="$1"
    echo "${input}" \
        | sed -E 's/[^A-Za-z0-9]+/_/g' \
        | sed -E 's/_+/_/g' \
        | sed -E 's/^_//; s/_$//'
}

get_existing_queues() {
    lpstat -p 2>/dev/null | awk '/^printer/ {print $2}'
}

EXISTING_QUEUES="$(get_existing_queues)"

queue_exists() {
    local queue_name="$1"
    echo "${EXISTING_QUEUES}" | grep -qx "${queue_name}"
}

declare -A SEEN_QUEUES=()

USB_URIS="$(lpinfo -v 2>/dev/null | awk '/usb:\/\//{print $2}')"

CHANGED=0

if [[ -z "${USB_URIS}" ]]; then
    log "No USB printers currently detected."
fi

while IFS= read -r uri; do
    [[ -z "${uri}" ]] && continue

    raw_path="${uri#usb://}"
    raw_path="${raw_path%%\?*}"
    manufacturer="${raw_path%%/*}"
    model_encoded="${raw_path#*/}"

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
        lpadmin -p "${queue_name}" -D "${description}" >/dev/null 2>&1
        lpadmin -p "${queue_name}" -o printer-is-shared=true >/dev/null 2>&1
        cupsenable "${queue_name}" >/dev/null 2>&1
        cupsaccept "${queue_name}" >/dev/null 2>&1
    else
        log "Configuring new printer: ${friendly_name} (uri: ${uri})"

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

        lpadmin -p "${queue_name}" -D "${description}" >/dev/null 2>&1
        lpadmin -p "${queue_name}" -o printer-is-shared=true >/dev/null 2>&1
        cupsenable "${queue_name}" >/dev/null 2>&1
        cupsaccept "${queue_name}" >/dev/null 2>&1

        CHANGED=1
    fi

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

if compgen -G "${AVAHI_SERVICES_DIR}/airprint-*.service" > /dev/null 2>&1; then
    for service_file in "${AVAHI_SERVICES_DIR}"/airprint-*.service; do
        base="$(basename "${service_file}")"
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

if command -v systemctl >/dev/null 2>&1; then
    systemctl reload avahi-daemon >/dev/null 2>&1 \
        || systemctl restart avahi-daemon >/dev/null 2>&1
fi

if [[ -x "${WEBPAGE_SCRIPT}" ]]; then
    "${WEBPAGE_SCRIPT}"
fi

log "cups-auto-add run complete. changed=${CHANGED}"
exit 0
AUTOADD_SCRIPT_EOF

chmod 755 "${BIN_DIR}/update-printer-webpage.sh" "${BIN_DIR}/cups-auto-add.sh"

# ---------------------------------------------------------------------------
# [6/9] Install udev rule (instant detection on connect)
# ---------------------------------------------------------------------------
step 6 "Installing udev rule"

cat > "${UDEV_RULE_PATH}" <<'UDEV_EOF'
# Unwire - udev rule
#
# Triggers automatic CUPS queue creation and AirPrint broadcast whenever
# a USB device with the Printer interface class (0x07) is added.
#
# Runs asynchronously via systemd-run so udev's event processing is never
# blocked while lpinfo/lpadmin/avahi work happens.

ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="07", \
  RUN+="/bin/systemd-run --no-block /usr/local/bin/cups-auto-add.sh"

ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:0701??:*", \
  RUN+="/bin/systemd-run --no-block /usr/local/bin/cups-auto-add.sh"
UDEV_EOF

chmod 644 "${UDEV_RULE_PATH}"
run_quiet udevadm control --reload-rules
run_quiet udevadm trigger

# ---------------------------------------------------------------------------
# [7/9] Install continuous scan timer (backstop for missed udev events,
#        and to detect printers being unplugged)
# ---------------------------------------------------------------------------
step 7 "Installing continuous printer scan"

cat > "${SYSTEMD_DIR}/unwire-scan.service" <<'SCAN_SERVICE_EOF'
[Unit]
Description=Unwire periodic USB printer scan
After=cups.service avahi-daemon.service
Wants=cups.service avahi-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cups-auto-add.sh
SCAN_SERVICE_EOF

cat > "${SYSTEMD_DIR}/unwire-scan.timer" <<'SCAN_TIMER_EOF'
[Unit]
Description=Run Unwire USB printer scan every 30 seconds

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=1s
Unit=unwire-scan.service

[Install]
WantedBy=timers.target
SCAN_TIMER_EOF

run_quiet systemctl daemon-reload
run_quiet systemctl enable unwire-scan.timer
run_quiet systemctl start unwire-scan.timer

# ---------------------------------------------------------------------------
# [8/9] Start/restart services and run initial discovery
# ---------------------------------------------------------------------------
step 8 "Starting services"
mkdir -p "${AVAHI_SERVICES_DIR}"

run_quiet systemctl enable cups
run_quiet systemctl enable avahi-daemon
run_quiet systemctl enable nginx

run_quiet systemctl restart cups
run_quiet systemctl restart avahi-daemon

# Run an initial discovery/configuration pass so any printers already
# plugged in at install time are picked up immediately (the timer will
# take over from here, running every 30 seconds indefinitely).
run_quiet "${BIN_DIR}/cups-auto-add.sh"

run_quiet nginx -t
run_quiet systemctl restart nginx

# ---------------------------------------------------------------------------
# [9/9] Done
# ---------------------------------------------------------------------------
step 9 "Finalizing"
PI_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo ""
echo "=============================================="
echo " Unwire installation complete!"
echo "=============================================="
echo ""
echo "  Dashboard:      http://unwire.local"
echo "  CUPS Admin:     http://admin.unwire.local"
echo "  Local IP:       http://${PI_IP:-<unknown>}"
echo ""
echo "  Plug in a USB printer at any time - it will be"
echo "  detected, shared, and AirPrint-broadcast"
echo "  automatically. Unwire scans for printer changes"
echo "  continuously every 30 seconds, in addition to"
echo "  reacting instantly to USB connect events, so"
echo "  disconnected printers are also detected and"
echo "  marked offline."
echo ""
echo "  Install log: ${LOG_FILE}"
echo "=============================================="