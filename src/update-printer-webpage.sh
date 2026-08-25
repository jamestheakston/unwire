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

# ---------------------------------------------------------------------------
# Gather printer data from CUPS.
#
# `lpstat -p` produces lines like:
#   printer HP_DeskJet_3630___Unwire is idle.  enabled since ...
#
# We cross-reference against `lpstat -l -p` / cupsd description output to
# get the human-readable description (set via lpadmin -D), which is what
# holds the "[Printer Name] - Unwire" string.
# ---------------------------------------------------------------------------
declare -a PRINTER_NAMES=()
declare -a PRINTER_STATES=()

if command -v lpstat >/dev/null 2>&1; then
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        queue_name="$(echo "${line}" | awk '{print $2}')"
        [[ -z "${queue_name}" ]] && continue

        # Determine online/idle vs disabled state from the lpstat line.
        if echo "${line}" | grep -qi "disabled"; then
            state="Offline"
        else
            state="Online"
        fi

        # Prefer the CUPS description (set to "[Printer Name] - Unwire"
        # by cups-auto-add.sh) over the raw queue name.
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

# ---------------------------------------------------------------------------
# Build the printer cards HTML fragment.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Write the dashboard HTML.
# ---------------------------------------------------------------------------
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
