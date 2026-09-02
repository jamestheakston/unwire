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
# Figure out how this Pi can actually be reached right now. .local (mDNS)
# names don't resolve on every network (client isolation, some routers,
# some OSes without Bonjour), so the dashboard always shows a direct IP
# fallback alongside the .local names rather than assuming either works.
# ---------------------------------------------------------------------------
PI_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${PI_IP}" ]] && PI_IP="unknown"

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

# ---------------------------------------------------------------------------
# Tally online/offline counts for the overview stat cards.
# ---------------------------------------------------------------------------
ONLINE_COUNT=0
OFFLINE_COUNT=0
for state in "${PRINTER_STATES[@]:-}"; do
    [[ -z "${state}" ]] && continue
    if [[ "${state}" == "Online" ]]; then
        ONLINE_COUNT=$((ONLINE_COUNT + 1))
    else
        OFFLINE_COUNT=$((OFFLINE_COUNT + 1))
    fi
done
TOTAL_COUNT=$((ONLINE_COUNT + OFFLINE_COUNT))

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
<title>Unwire — AirPrint Hub</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #090d16;
    --bg-elevated: #101729;
    --bg-elevated-2: #161f38;
    --border: #212c48;
    --text-primary: #f3f4f6;
    --text-secondary: #8996b3;
    --text-tertiary: #5a6584;
    --green: #10b981;
    --green-dim: rgba(16, 185, 129, 0.12);
    --amber: #f59e0b;
    --amber-dim: rgba(245, 158, 11, 0.1);
    --sidebar-w: 236px;
  }

  * { box-sizing: border-box; }

  html { scroll-behavior: smooth; }

  body {
    margin: 0;
    background: var(--bg);
    background-image:
      radial-gradient(ellipse 800px 400px at 15% -10%, rgba(16, 185, 129, 0.07), transparent),
      radial-gradient(ellipse 800px 400px at 100% 10%, rgba(56, 189, 248, 0.06), transparent);
    color: var(--text-primary);
    font-family: 'Space Grotesk', sans-serif;
    min-height: 100vh;
  }

  /* ---------- Sidebar ---------- */
  .sidebar {
    position: fixed;
    top: 0;
    left: 0;
    bottom: 0;
    width: var(--sidebar-w);
    border-right: 1px solid var(--border);
    background: var(--bg-elevated);
    padding: 26px 18px;
    display: flex;
    flex-direction: column;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 4px;
    padding: 0 6px;
  }

  .brand-mark {
    width: 30px;
    height: 30px;
    border-radius: 8px;
    background: linear-gradient(135deg, #059669, #047857);
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 15px;
  }

  .brand h1 {
    font-size: 17px;
    font-weight: 700;
    letter-spacing: -0.01em;
    margin: 0;
  }

  .status-pill {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    background: var(--green-dim);
    border: 1px solid rgba(16, 185, 129, 0.3);
    color: var(--green);
    padding: 6px 12px 6px 10px;
    border-radius: 999px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 11.5px;
    font-weight: 500;
    margin: 16px 6px 26px;
    width: fit-content;
  }

  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--green);
    box-shadow: 0 0 8px var(--green);
    flex-shrink: 0;
  }

  .nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .nav a {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 10px 12px;
    border-radius: 9px;
    color: var(--text-secondary);
    text-decoration: none;
    font-size: 14px;
    font-weight: 500;
    transition: background 0.15s ease, color 0.15s ease;
  }

  .nav a .nav-label { display: flex; align-items: center; gap: 10px; }

  .nav a:hover { background: var(--bg-elevated-2); color: var(--text-primary); }

  .nav a.active {
    background: var(--bg-elevated-2);
    color: var(--text-primary);
  }

  .nav-count {
    font-family: 'JetBrains Mono', monospace;
    font-size: 11px;
    color: var(--text-tertiary);
    background: rgba(255,255,255,0.05);
    padding: 2px 7px;
    border-radius: 999px;
  }

  .sidebar-footer {
    margin-top: auto;
    padding: 12px 12px 4px;
    border-top: 1px solid var(--border);
    font-family: 'JetBrains Mono', monospace;
    font-size: 11px;
    color: var(--text-tertiary);
    line-height: 1.6;
  }

  /* ---------- Main content ---------- */
  .main {
    margin-left: var(--sidebar-w);
    padding: 40px 44px 60px;
    max-width: 860px;
  }

  section { scroll-margin-top: 32px; margin-bottom: 48px; }

  section h2 {
    font-size: 13px;
    text-transform: none;
    color: var(--text-secondary);
    font-weight: 600;
    margin: 0 0 16px;
  }

  /* ---------- Hero animation ---------- */
  .hero {
    background: linear-gradient(180deg, var(--bg-elevated), var(--bg-elevated-2));
    border: 1px solid var(--border);
    border-radius: 20px;
    padding: 16px 8px 4px;
    margin-bottom: 18px;
    overflow: hidden;
  }

  .hero svg { width: 100%; height: auto; display: block; }

  .glow-pi { filter: drop-shadow(0 0 18px rgba(225, 29, 72, 0.35)); }
  .glow-printer { filter: drop-shadow(0 0 22px rgba(59, 130, 246, 0.3)); }
  .data-stream { stroke-dasharray: 16, 24; animation: flowData 0.4s linear infinite; }
  @keyframes flowData { 0% { stroke-dashoffset: 40; } 100% { stroke-dashoffset: 0; } }

  /* ---------- Stat cards ---------- */
  .stats {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 14px;
  }

  .stat-card {
    background: var(--bg-elevated);
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 18px 20px;
  }

  .stat-value {
    font-family: 'JetBrains Mono', monospace;
    font-size: 26px;
    font-weight: 600;
    margin: 0 0 3px;
  }

  .stat-value.green { color: var(--green); }
  .stat-value.amber { color: var(--amber); }

  .stat-label {
    font-size: 12.5px;
    color: var(--text-secondary);
    margin: 0;
  }

  /* ---------- Printer list ---------- */
  .printer-list {
    background: var(--bg-elevated);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 6px 20px;
  }

  .printer-card {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 16px 0;
    border-top: 1px solid var(--border);
  }

  .printer-card:first-child { border-top: none; }

  .printer-info { display: flex; align-items: center; gap: 12px; }
  .printer-icon { font-size: 19px; }
  .printer-name { font-size: 14.5px; font-weight: 500; }

  .badge {
    font-family: 'JetBrains Mono', monospace;
    font-size: 11.5px;
    font-weight: 500;
    padding: 4px 11px;
    border-radius: 999px;
  }

  .badge-online { background: var(--green-dim); color: var(--green); }
  .badge-offline { background: rgba(239, 68, 68, 0.12); color: #f87171; }

  .empty-state { text-align: center; padding: 30px 0; }
  .empty-state p { margin: 0 0 4px; color: var(--text-secondary); }
  .empty-sub { font-size: 13px; color: var(--text-tertiary) !important; }

  /* ---------- Access section ---------- */
  .notice {
    display: flex;
    gap: 12px;
    background: var(--amber-dim);
    border: 1px solid rgba(245, 158, 11, 0.28);
    border-radius: 14px;
    padding: 15px 18px;
    margin-bottom: 16px;
  }

  .notice-icon {
    color: var(--amber);
    font-family: 'JetBrains Mono', monospace;
    font-weight: 600;
    font-size: 13px;
    flex-shrink: 0;
  }

  .notice p { margin: 0; font-size: 13.5px; line-height: 1.55; color: #e2c08d; }

  .card {
    background: var(--bg-elevated);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 6px 22px;
  }

  .link-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 16px 0;
    border-top: 1px solid var(--border);
    flex-wrap: wrap;
  }

  .link-row:first-child { border-top: none; }

  .link-label { font-size: 13px; color: var(--text-secondary); margin: 0 0 6px; }

  .link-options { display: flex; gap: 8px; flex-wrap: wrap; }

  .link-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: var(--bg-elevated-2);
    border: 1px solid var(--border);
    color: var(--text-primary);
    text-decoration: none;
    font-family: 'JetBrains Mono', monospace;
    font-size: 12.5px;
    padding: 8px 13px;
    border-radius: 8px;
    transition: background 0.15s ease, border-color 0.15s ease;
  }

  .link-btn:hover { background: #1c2745; border-color: #2c3a5e; }

  footer.page-footer {
    text-align: left;
    color: var(--text-tertiary);
    font-size: 12.5px;
    margin-top: 8px;
  }

  @media (max-width: 880px) {
    .sidebar {
      position: static;
      width: auto;
      height: auto;
      flex-direction: row;
      align-items: center;
      overflow-x: auto;
      border-right: none;
      border-bottom: 1px solid var(--border);
      padding: 14px 16px;
      gap: 18px;
    }
    .status-pill { display: none; }
    .sidebar-footer { display: none; }
    .nav { flex-direction: row; }
    .main { margin-left: 0; padding: 28px 20px 50px; }
    .stats { grid-template-columns: 1fr 1fr 1fr; }
  }

  @media (max-width: 560px) {
    .stats { grid-template-columns: 1fr; }
    .link-row { flex-direction: column; align-items: flex-start; }
  }

  @media (prefers-reduced-motion: reduce) {
    .data-stream { animation: none; }
  }
</style>
</head>
<body>

  <nav class="sidebar">
    <div class="brand">
      <div class="brand-mark">&#128225;</div>
      <h1>Unwire</h1>
    </div>

    <div class="status-pill">
      <span class="status-dot"></span>
      Online
    </div>

    <div class="nav">
      <a href="#overview" class="nav-link active">
        <span class="nav-label">Overview</span>
      </a>
      <a href="#printers" class="nav-link">
        <span class="nav-label">Printers</span>
        <span class="nav-count">${TOTAL_COUNT}</span>
      </a>
      <a href="#access" class="nav-link">
        <span class="nav-label">Access</span>
      </a>
    </div>

    <div class="sidebar-footer">
      ${PI_IP}<br>
      Updated ${GENERATED_AT}
    </div>
  </nav>

  <main class="main">

    <section id="overview">
      <h2>Overview</h2>

      <div class="hero">
        <svg viewBox="0 0 960 400" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="piGrad" x1="0%" y1="0%" x2="100%" y2="100%">
              <stop offset="0%" stop-color="#059669" />
              <stop offset="100%" stop-color="#047857" />
            </linearGradient>
            <linearGradient id="chipGrad" x1="0%" y1="0%" x2="100%" y2="100%">
              <stop offset="0%" stop-color="#334155" />
              <stop offset="100%" stop-color="#0f172a" />
            </linearGradient>
            <linearGradient id="printerGrad" x1="0%" y1="0%" x2="0%" y2="100%">
              <stop offset="0%" stop-color="#f8fafc" />
              <stop offset="100%" stop-color="#cbd5e1" />
            </linearGradient>
            <linearGradient id="printerDark" x1="0%" y1="0%" x2="0%" y2="100%">
              <stop offset="0%" stop-color="#334155" />
              <stop offset="100%" stop-color="#1e293b" />
            </linearGradient>
            <linearGradient id="cableGrad" x1="0%" y1="0%" x2="100%" y2="0%">
              <stop offset="0%" stop-color="#38bdf8" />
              <stop offset="50%" stop-color="#818cf8" />
              <stop offset="100%" stop-color="#34d399" />
            </linearGradient>
            <filter id="glow" x="-20%" y="-20%" width="140%" height="140%">
              <feGaussianBlur stdDeviation="6" result="blur" />
              <feComposite in="SourceGraphic" in2="blur" operator="over" />
            </filter>
          </defs>

          <g class="glow-pi" transform="translate(40, 80) scale(1.1)">
            <rect x="0" y="0" width="220" height="150" rx="14" fill="url(#piGrad)" stroke="#10b981" stroke-width="2" />
            <g transform="translate(200, 16)">
              <rect x="0" y="0" width="28" height="42" rx="3" fill="#94a3b8" stroke="#64748b" stroke-width="1" />
              <rect x="0" y="4" width="22" height="34" fill="#0f172a" />
              <rect x="2" y="16" width="18" height="10" fill="#0284c7" />
            </g>
            <g transform="translate(200, 76)">
              <rect x="0" y="0" width="28" height="42" rx="3" fill="#94a3b8" stroke="#64748b" stroke-width="1" />
              <rect x="0" y="4" width="22" height="34" fill="#0f172a" />
              <rect x="2" y="16" width="18" height="10" fill="#0284c7" />
            </g>
            <rect x="135" y="130" width="50" height="25" rx="3" fill="#cbd5e1" stroke="#64748b" stroke-width="1" />
            <rect x="140" y="135" width="40" height="20" fill="#475569" />
            <g fill="#e2e8f0">
              <rect x="18" y="8" width="170" height="12" rx="2" fill="#1e293b" />
              <circle cx="28" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="40" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="52" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="64" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="76" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="88" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="100" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="112" cy="14" r="2.5" fill="#f59e0b" />
              <circle cx="124" cy="14" r="2.5" fill="#f59e0b" />
            </g>
            <rect x="75" y="50" width="50" height="50" rx="6" fill="url(#chipGrad)" stroke="#475569" stroke-width="1.5" />
            <path d="M 90 62 L 110 62 M 100 52 L 100 72" stroke="#64748b" stroke-width="2" />
            <circle cx="100" cy="85" r="4" fill="#be123c" />
            <rect x="22" y="60" width="30" height="30" rx="4" fill="url(#chipGrad)" stroke="#475569" />
            <circle cx="18" cy="128" r="4" fill="#ef4444" />
            <circle id="pi-led" cx="32" cy="128" r="4" fill="#10b981" opacity="0.3" />
            <circle cx="12" cy="12" r="4" fill="#047857" />
            <circle cx="208" cy="12" r="4" fill="#047857" />
            <circle cx="12" cy="138" r="4" fill="#047857" />
            <circle cx="208" cy="138" r="4" fill="#047857" />
            <text x="68" y="120" font-size="12" font-weight="800" fill="#f43f5e" font-family="sans-serif" letter-spacing="0.5">RASPBERRY PI</text>
          </g>

          <g transform="translate(282, 172)">
            <rect x="0" y="0" width="22" height="26" rx="3" fill="#334155" />
            <rect x="-12" y="3" width="12" height="20" rx="2" fill="#94a3b8" />
          </g>

          <path id="cable-outer" d="M 285 185 Q 360 300 440 270" fill="none" stroke="#0f172a" stroke-width="14" stroke-linecap="round" />
          <path id="cable-inner" d="M 285 185 Q 360 300 440 270" fill="none" stroke="#334155" stroke-width="8" stroke-linecap="round" />
          <path id="cable-data" d="M 285 185 Q 360 300 440 270" fill="none" stroke="url(#cableGrad)" stroke-width="5" stroke-linecap="round" class="data-stream" opacity="0" filter="url(#glow)" />

          <g id="tick-mark" transform="translate(450, 115) scale(0)" opacity="0" filter="url(#glow)">
            <circle cx="0" cy="0" r="28" fill="#10b981" />
            <path d="M -12 -1 L -3 8 L 12 -8" fill="none" stroke="#ffffff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round" />
          </g>

          <g id="plug" transform="translate(440, 270) rotate(-22)">
            <rect x="-35" y="-14" width="24" height="28" rx="4" fill="#334155" />
            <rect x="-11" y="-11" width="22" height="22" rx="3" fill="#cbd5e1" stroke="#94a3b8" stroke-width="1.5" />
            <rect x="-2" y="-7" width="9" height="14" fill="#0284c7" />
            <path d="M -28 -7 L -20 -7 M -28 0 L -20 0 M -28 7 L -20 7" stroke="#64748b" stroke-width="2" />
          </g>

          <g class="glow-printer" transform="translate(620, 65) scale(1.1)">
            <path d="M 30 20 L 150 20 L 165 60 L 15 60 Z" fill="#e2e8f0" stroke="#cbd5e1" stroke-width="2" />
            <rect x="0" y="55" width="230" height="140" rx="16" fill="url(#printerGrad)" stroke="#94a3b8" stroke-width="2" />
            <rect x="35" y="70" width="170" height="40" rx="8" fill="url(#printerDark)" />
            <circle id="printer-led" cx="185" cy="90" r="8" fill="#f59e0b" filter="drop-shadow(0 0 6px #f59e0b)" />
            <rect x="50" y="80" width="90" height="20" rx="4" fill="#0f172a" />
            <rect x="55" y="85" width="45" height="10" rx="2" fill="#0284c7" />
            <g transform="translate(0, 108)">
              <rect x="-4" y="-16" width="16" height="32" rx="4" fill="#0f172a" stroke="#64748b" stroke-width="2" />
              <rect x="-1" y="-11" width="10" height="22" rx="2" fill="#0284c7" />
              <rect x="1" y="-8" width="6" height="16" fill="#000000" />
            </g>
            <text x="115" y="165" font-size="12" font-weight="800" fill="#334155" text-anchor="middle" font-family="sans-serif" letter-spacing="1">PRINTER</text>
          </g>

          <ellipse cx="160" cy="275" rx="130" ry="16" fill="#000000" opacity="0.4" filter="url(#glow)" />
          <ellipse cx="750" cy="295" rx="140" ry="18" fill="#000000" opacity="0.4" filter="url(#glow)" />
        </svg>
      </div>

      <div class="stats">
        <div class="stat-card">
          <p class="stat-value">${TOTAL_COUNT}</p>
          <p class="stat-label">Total printers</p>
        </div>
        <div class="stat-card">
          <p class="stat-value green">${ONLINE_COUNT}</p>
          <p class="stat-label">Online</p>
        </div>
        <div class="stat-card">
          <p class="stat-value amber">${OFFLINE_COUNT}</p>
          <p class="stat-label">Offline</p>
        </div>
      </div>
    </section>

    <section id="printers">
      <h2>Printers</h2>
      <div class="printer-list">
${PRINTER_CARDS_HTML}
      </div>
    </section>

    <section id="access">
      <h2>Access</h2>

      <div class="notice">
        <span class="notice-icon">!</span>
        <p>
          <code>.local</code> names only resolve on networks that support mDNS.
          If <code>unwire.local</code> doesn't load for you, use the direct IP
          links instead — they always work.
        </p>
      </div>

      <div class="card">
        <div class="link-row">
          <div>
            <p class="link-label">Dashboard (this page)</p>
          </div>
          <div class="link-options">
            <a class="link-btn" href="http://unwire.local" target="_blank" rel="noopener">unwire.local</a>
            <a class="link-btn" href="http://${PI_IP}" target="_blank" rel="noopener">${PI_IP}</a>
          </div>
        </div>
        <div class="link-row">
          <div>
            <p class="link-label">CUPS administration</p>
          </div>
          <div class="link-options">
            <a class="link-btn" href="http://admin.unwire.local" target="_blank" rel="noopener">admin.unwire.local</a>
            <a class="link-btn" href="http://${PI_IP}:631" target="_blank" rel="noopener">${PI_IP}:631</a>
          </div>
        </div>
      </div>

      <footer class="page-footer">Powered by open-source software — CUPS, Avahi &amp; Nginx</footer>
    </section>

  </main>

  <script>
    var cableOuter = document.getElementById('cable-outer');
    var cableInner = document.getElementById('cable-inner');
    var cableData = document.getElementById('cable-data');
    var plug = document.getElementById('plug');
    var piLed = document.getElementById('pi-led');
    var printerLed = document.getElementById('printer-led');
    var tickMark = document.getElementById('tick-mark');

    var startX = 285;
    var startY = 185;

    var unpluggedX = 420;
    var unpluggedY = 270;
    var unpluggedAngle = -22;
    var unpluggedControlX = 350;
    var unpluggedControlY = 320;

    var pluggedX = 618;
    var pluggedY = 184;
    var pluggedAngle = 0;
    var pluggedControlX = 450;
    var pluggedControlY = 184;

    var cycleDuration = 7200;
    var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function easeInOutCubic(t) {
      return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
    }

    function render(progress, tickScale, tickOpacity) {
      var currentX = unpluggedX + (pluggedX - unpluggedX) * progress;
      var currentY = unpluggedY + (pluggedY - unpluggedY) * progress;
      var currentAngle = unpluggedAngle + (pluggedAngle - unpluggedAngle) * progress;
      var currentControlX = unpluggedControlX + (pluggedControlX - unpluggedControlX) * progress;
      var currentControlY = unpluggedControlY + (pluggedControlY - unpluggedControlY) * progress;

      var pathD = "M " + startX + " " + startY + " Q " + currentControlX + " " + currentControlY + " " + currentX + " " + currentY;
      cableOuter.setAttribute('d', pathD);
      cableInner.setAttribute('d', pathD);
      cableData.setAttribute('d', pathD);
      plug.setAttribute('transform', "translate(" + currentX + ", " + currentY + ") rotate(" + currentAngle + ")");

      if (progress >= 0.98) {
        cableData.style.opacity = '1';
        piLed.style.opacity = '1';
        piLed.style.filter = 'drop-shadow(0 0 8px #10b981)';
        printerLed.setAttribute('fill', '#10b981');
        printerLed.style.filter = 'drop-shadow(0 0 10px #10b981)';
      } else {
        cableData.style.opacity = '0';
        piLed.style.opacity = '0.3';
        piLed.style.filter = 'none';
        printerLed.setAttribute('fill', '#f59e0b');
        printerLed.style.filter = 'drop-shadow(0 0 6px #f59e0b)';
      }

      tickMark.setAttribute('transform', "translate(450, 115) scale(" + tickScale + ")");
      tickMark.style.opacity = tickOpacity.toString();
    }

    if (reduceMotion) {
      render(1, 1, 1);
    } else {
      (function () {
        function animate(timestamp) {
          var elapsed = timestamp % cycleDuration;
          var progress = 0;

          if (elapsed < 800) {
            progress = 0;
          } else if (elapsed < 2400) {
            progress = easeInOutCubic((elapsed - 800) / 1600);
          } else if (elapsed < 5800) {
            progress = 1;
          } else {
            progress = 1 - easeInOutCubic((elapsed - 5800) / 1400);
          }

          var tickScale = 0;
          var tickOpacity = 0;

          if (elapsed >= 2400 && elapsed < 5800) {
            var pluggedElapsed = elapsed - 2400;
            if (pluggedElapsed < 150) {
              tickScale = (pluggedElapsed / 150) * 1.15;
              tickOpacity = pluggedElapsed / 150;
            } else if (pluggedElapsed < 300) {
              tickScale = 1.15 - ((pluggedElapsed - 150) / 150) * 0.15;
              tickOpacity = 1;
            } else if (pluggedElapsed < 3100) {
              tickScale = 1;
              tickOpacity = 1;
            } else {
              var fadeProgress = (pluggedElapsed - 3100) / 300;
              tickScale = 1 - fadeProgress;
              tickOpacity = 1 - fadeProgress;
            }
          }

          tickScale = Math.max(0, tickScale);
          tickOpacity = Math.max(0, Math.min(1, tickOpacity));

          render(progress, tickScale, tickOpacity);
          requestAnimationFrame(animate);
        }

        requestAnimationFrame(animate);
      })();
    }

    // Highlight the active sidebar link as each section scrolls into view.
    var navLinks = document.querySelectorAll('.nav-link');
    var sections = document.querySelectorAll('main section');

    if ('IntersectionObserver' in window) {
      var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            var id = entry.target.getAttribute('id');
            navLinks.forEach(function (link) {
              link.classList.toggle('active', link.getAttribute('href') === '#' + id);
            });
          }
        });
      }, { rootMargin: '-40% 0px -55% 0px' });

      sections.forEach(function (section) { observer.observe(section); });
    }
  </script>
</body>
</html>
HTML

chmod 644 "${OUTPUT_FILE}"
log "Dashboard regenerated with ${#PRINTER_NAMES[@]} printer(s)."

exit 0
