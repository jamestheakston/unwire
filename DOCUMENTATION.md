# Unwire Documentation

Complete reference for installing, operating, and troubleshooting Unwire.

## Table of Contents

1. [Overview](#1-overview)
2. [Requirements](#2-requirements)
3. [Recommended Hardware](#3-recommended-hardware)
4. [Installation](#4-installation)
5. [Architecture & How It Works](#5-architecture--how-it-works)
6. [Accessing the Dashboard](#6-accessing-the-dashboard)
7. [Accessing CUPS Administration](#7-accessing-cups-administration)
8. [Printing From Your Devices](#8-printing-from-your-devices)
9. [Supported Printers & Drivers](#9-supported-printers--drivers)
10. [Manually Configuring a Driver (Unsupported Printers)](#10-manually-configuring-a-driver-unsupported-printers)
11. [How Automatic Printer Detection Works](#11-how-automatic-printer-detection-works)
12. [Networking Requirements (.local / mDNS)](#12-networking-requirements-local--mdns)
13. [Logs & Diagnostics](#13-logs--diagnostics)
14. [Troubleshooting](#14-troubleshooting)
15. [Uninstalling](#15-uninstalling)
16. [License](#16-license)

---

## 1. Overview

Unwire is a zero-configuration utility that turns a Raspberry Pi (or any Debian/Ubuntu-based Linux machine) into a wireless **AirPrint hub** for USB-only printers. Plug a printer into the Pi's USB port, and every iPhone, iPad, and Mac on the same local network can print to it — no drivers, no apps, no per-device setup.

Under the hood, Unwire combines and automates four existing open-source technologies:

- **CUPS** — the print server that manages printer queues and handles print jobs.
- **Avahi** — broadcasts each printer over the network via DNS-SD/mDNS so Apple devices can discover it as an AirPrint printer.
- **Nginx** — serves a status dashboard and reverse-proxies CUPS's admin interface.
- **udev + a systemd timer** — detect USB printers automatically, both instantly on plug-in and via a continuous background scan.

---

## 2. Requirements

- A Raspberry Pi (or any Debian/Ubuntu-based Linux box) that you can run commands on as root/sudo.
- **The device must already be connected to the internet** (Wi-Fi or Ethernet) *before* running the installer — it downloads packages via `apt` during setup.
- One or more USB printers.
- A phone, tablet, or computer on the **same local network** as the Pi, to print and to view the dashboard/admin pages.

---

## 3. Recommended Hardware

| Tier | Model | Notes |
|---|---|---|
| Minimum | Raspberry Pi Zero 2 W | Quad-core, 512MB RAM — enough for CUPS + Nginx + Avahi. Only has a micro-USB OTG port, so a USB hub/adapter may be needed for the printer connection. |
| Recommended | Raspberry Pi 3B+ or Raspberry Pi 4 (1GB) | Built-in Ethernet, more headroom for driver rasterization on larger print jobs, more comfortable for frequent/multi-device use. |

Avoid the original Pi Zero W and Pi 1-series boards — they'll technically run the stack, but printing will feel sluggish, especially for non-PostScript printers that need CPU-side rasterization.

The real bottleneck for AirPrint responsiveness is network connectivity, not CPU power — a fast, stable connection matters more than raw compute.

---

## 4. Installation

Run this single command on the Pi, with the Pi already connected to the internet:

```bash
curl -sSL https://raw.githubusercontent.com/jamestheakston/unwire/main/install.sh | sudo bash
```

This one command:

1. Installs CUPS, Avahi, Nginx, and driver packages.
2. Sets the device's hostname to `unwire`.
3. Configures CUPS for remote administration and sharing.
4. Configures Nginx to serve the dashboard and proxy CUPS admin.
5. Installs the udev rule and systemd timer for automatic printer detection.
6. Runs an initial scan to pick up any printer already plugged in.
7. Prints a summary with the dashboard URL, admin URL, and local IP.

No further steps are required — printers plugged in after installation are detected automatically (see [Section 11](#11-how-automatic-printer-detection-works)).

---

## 5. Architecture & How It Works

| Component | Purpose |
|---|---|
| `install.sh` | One-shot installer — installs packages, configures CUPS/Nginx/Avahi, and deploys everything below. |
| `src/cups-auto-add.sh` | Detects USB printers, creates CUPS queues, generates AirPrint Avahi service files, disables queues for printers that are no longer connected. |
| `src/update-printer-webpage.sh` | Regenerates the status dashboard at `/var/www/html/index.html`. |
| `src/99-cups-autorun.rules` | udev rule that triggers instant detection the moment a USB printer is plugged in. |
| `src/unwire-scan.service` / `src/unwire-scan.timer` | systemd timer that re-runs the detection scan every 30 seconds, as a backstop for missed udev events and to catch printers being unplugged. |

Every printer Unwire manages is named `[Printer Name] - Unwire` consistently across the CUPS queue description, the AirPrint broadcast name, and the dashboard, so it's easy to identify in any printer picker.

---

## 6. Accessing the Dashboard

Open **`http://unwire.local`** from any device on the same local network as the Pi.

The dashboard shows:

- Every currently configured printer.
- A green "Online" badge for printers that are connected and enabled.
- A red "Offline" badge for printers that were previously configured but are no longer physically connected.
- A direct link to the CUPS admin page.

The dashboard is regenerated automatically every time a printer is added, removed, or its status changes — you don't need to refresh anything manually, though you may need to reload the page in your browser to see the update.

You can also usually reach the dashboard using the Pi's raw IP address (e.g. `http://192.168.1.42`) — this works because Nginx treats the dashboard's server block as the default when no hostname matches, though this behavior is not guaranteed to be permanent. The admin page does **not** work this way; it can only be reached via `admin.unwire.local`.

---

## 7. Accessing CUPS Administration

Open **`http://admin.unwire.local`** from a device on the same local network. This is a reverse proxy straight through to CUPS's own web administration interface, running on port 631 on the Pi itself.

From here you can:

- Add, remove, or modify printers manually.
- View and manage the print queue and job history.
- Change printer settings (paper size, duplex, quality, etc.).
- Manually assign a specific driver/PPD to a printer (see [Section 10](#10-manually-configuring-a-driver-unsupported-printers)).

---

## 8. Printing From Your Devices

On any Mac or iOS device connected to the same local network as the Pi:

1. Open **Print** from any app.
2. Select **Printer**.
3. Your printer will appear as `[Printer Name] - Unwire`.
4. Print — no drivers or additional setup required on the device.

If the printer doesn't appear in the list, see [Troubleshooting](#14-troubleshooting).

---

## 9. Supported Printers & Drivers

Unwire installs several driver packages during setup to cover as many printers as possible automatically:

| Package | Covers |
|---|---|
| CUPS (built-in) | IPP Everywhere / driverless printing — handles most printers made since roughly 2010, regardless of brand, without needing a specific driver package. |
| `printer-driver-gutenprint` | Broad general-purpose driver set, especially strong for Epson and Canon inkjets, plus many older/budget printers. |
| `hplip` | HP's official Linux driver suite — covers most HP DeskJet, OfficeJet, LaserJet, and Envy printers. |
| `brlaser` | Lightweight open-source driver for Brother laser printers (HL-, DCP-, MFC- series). |
| `printer-driver-splix` | Driver for Samsung/Xerox/Dell printers that use Samsung's SPL/SPL2/QPDL print language. |

When a printer is detected, `cups-auto-add.sh` tries these in order:

1. **IPP Everywhere** (driverless) — works for most modern printers regardless of brand.
2. **A matching driver name** found by searching `lpinfo -m` output against the printer's manufacturer/model string.
3. **A generic Gutenprint queue** as a broader fallback.
4. **A raw queue** as the last resort, with no format conversion — this often produces garbled or no output for printers using a proprietary command language.

**A note on older Samsung SPL printers:** some models (for example, the Samsung ML-1665) are not on SpliX's officially supported list even though the package is installed. These printers may land in the raw-queue fallback rather than being configured correctly. If a Samsung laser prints garbled output or nothing at all, this is the most likely cause — see [Section 10](#10-manually-configuring-a-driver-unsupported-printers) for the fix, and check [OpenPrinting's SpliX page](https://www.openprinting.org/driver/SpliX/) for your specific model's support status.

---

## 10. Manually Configuring a Driver (Unsupported Printers)

If a printer isn't automatically configured correctly — garbled output, blank pages, or no printing at all — you can manually assign a driver through the CUPS admin interface. CUPS supports this natively; Unwire doesn't need to add anything extra for this to work.

### Option A: Provide your own PPD file

1. Go to **`http://admin.unwire.local`**.
2. Click **Administration** → **Add Printer** (or select the existing printer and choose **Modify Printer**).
3. When asked to choose a driver, select the option to **provide a PPD file** rather than picking from the list.
4. Browse to and select a `.ppd` file for your printer. You can often find community-contributed PPDs on sites like [OpenPrinting](https://www.openprinting.org/printers) for printers not covered by the bundled driver packages.
5. Complete the setup and print a test page.

### Option B: Borrow the PPD from a similar supported model

For printers using a proprietary protocol where the exact model isn't officially supported (like the ML-1665 example above), a common workaround is to select the driver for a closely related model that *is* supported:

1. Go to **`http://admin.unwire.local`** → **Administration** → **Modify Printer** for the affected queue.
2. When choosing a driver, search the built-in driver list for a similar model from the same printer family (for example, ML-1660 or ML-1610 in place of ML-1665).
3. Save and print a test page to confirm it works correctly.

### A caveat about manual configuration

Unwire's background scanner (`cups-auto-add.sh`) re-checks connected printers every 30 seconds. Currently, if a manually-configured printer is unplugged and reconnected, the scanner may re-run its own automatic driver-matching logic on it rather than remembering your manual choice. If this happens, simply repeat the manual configuration steps above. This is a known limitation and a candidate for a future improvement (tracking which queues have been manually configured so the scanner leaves them alone).

---

## 11. How Automatic Printer Detection Works

Unwire detects printers through two independent mechanisms that work together:

1. **Instant detection via udev** — a udev rule watches for any USB device reporting the printer interface class. The moment a printer is plugged in, it triggers `cups-auto-add.sh` in the background.
2. **Continuous background scan via systemd timer** — `unwire-scan.timer` runs the same script every 30 seconds regardless of udev events. This acts as a backstop in case a udev event is missed, and is also how Unwire detects when a printer has been **unplugged** — a printer that no longer appears in the scan gets its CUPS queue disabled and its AirPrint broadcast removed, so it shows as "Offline" on the dashboard and stops advertising over the network.

Both mechanisms call the same script and are safe to run concurrently — a lock file prevents overlapping runs.

---

## 12. Networking Requirements (.local / mDNS)

The `unwire.local` and `admin.unwire.local` addresses rely on **mDNS (multicast DNS)**, also known as Bonjour, to resolve on your local network. This only works within your local network — it is never reachable over the internet or from a different network.

Platform support varies:

- **macOS / iOS** — mDNS support is built in; `.local` addresses work with no extra setup.
- **Windows** — requires Bonjour Print Services to be installed (this is bundled with iTunes, or can be installed standalone) for `.local` addresses to resolve. Without it, Windows will not find `unwire.local` at all.
- **Android / Linux** — generally works if mDNS support is present on the device, but this varies.
- **Corporate or guest Wi-Fi networks** — some networks block mDNS multicast traffic entirely as a security measure, which will prevent both `.local` resolution and AirPrint discovery from working, regardless of device.

If `.local` addresses aren't resolving, try the Pi's raw IP address for the dashboard (see [Section 6](#6-accessing-the-dashboard)), and confirm your network allows mDNS/multicast traffic.

---

## 13. Logs & Diagnostics

| What | Where |
|---|---|
| Installation log | `/var/log/unwire-install.log` |
| Printer detection/configuration log | `journalctl -t unwire-auto-add` |
| Dashboard generation log | `journalctl -t unwire-webpage` |

Useful commands for checking system state directly:

```bash
# List all configured CUPS queues and their status
lpstat -p

# Show detailed info (including description) for a specific queue
lpstat -l -p <queue_name>

# List detected USB printer URIs
lpinfo -v

# Check whether the continuous scan timer is running
systemctl status unwire-scan.timer

# Manually trigger a detection scan right now
sudo /usr/local/bin/cups-auto-add.sh

# Manually regenerate the dashboard
sudo /usr/local/bin/update-printer-webpage.sh
```

---

## 14. Troubleshooting

**A printer doesn't appear on the dashboard or in the AirPrint picker at all.**
- Confirm the printer is powered on and the USB cable is fully connected.
- Run `lpinfo -v` on the Pi and check for a `usb://` entry for the printer.
- Manually trigger a scan: `sudo /usr/local/bin/cups-auto-add.sh`, then check `journalctl -t unwire-auto-add` for errors.

**The printer appears but prints garbled text or blank pages.**
- This usually means the wrong driver was auto-selected, often for printers using a proprietary command language (see [Section 9](#9-supported-printers--drivers)).
- Follow the manual driver configuration steps in [Section 10](#10-manually-configuring-a-driver-unsupported-printers).

**`unwire.local` or `admin.unwire.local` won't load.**
- Confirm your device is on the same local network as the Pi.
- On Windows, confirm Bonjour Print Services is installed.
- Try the Pi's raw IP address instead (find it via the installer's completion summary, or run `hostname -I` on the Pi).
- Confirm your network doesn't block mDNS/multicast traffic (common on some corporate or guest networks).

**A printer shows "Offline" on the dashboard even though it's plugged in.**
- Wait up to 30 seconds — the background scan may not have run yet.
- Confirm the USB connection is solid; a loose connection can cause it to intermittently drop out of `lpinfo -v`.
- Run `sudo /usr/local/bin/cups-auto-add.sh` manually and check the log output.

**A manually-configured driver reverted after unplugging/replugging the printer.**
- This is a known limitation described in [Section 10](#10-manually-configuring-a-driver-unsupported-printers) — repeat the manual configuration steps.

---

## 15. Uninstalling

```bash
sudo systemctl disable --now unwire-scan.timer
sudo rm -f /etc/systemd/system/unwire-scan.{service,timer}
sudo rm -f /etc/udev/rules.d/99-cups-autorun.rules
sudo rm -f /usr/local/bin/cups-auto-add.sh /usr/local/bin/update-printer-webpage.sh
sudo rm -f /etc/nginx/sites-enabled/unwire.conf /etc/nginx/sites-available/unwire.conf
sudo systemctl restart nginx
```

CUPS, Avahi, and Nginx themselves are left installed, since other software on the system may depend on them. Remove them with `apt remove` if they're no longer needed.

---

## 16. License

Unwire is released under the MIT License. See [LICENSE](LICENSE) for the full text.