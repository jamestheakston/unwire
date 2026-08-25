# unwire

![AirPrint Compatible](https://img.shields.io/badge/AirPrint-Compatible-blue?style=flat-square&logo=apple)
![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi-C51A4A?style=flat-square&logo=raspberry-pi)
![License](https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square)

Turn any USB-only printer into a wireless one with one command.

Unwire is a zero-configuration utility that turns a Raspberry Pi into a wireless **AirPrint hub** for USB only printers. Plug a printer into the Pi, and every iPhone, iPad, and Mac on the same network as the Pi can print to it without any additional setup.

## Quick start

```bash
curl -sSL https://raw.githubusercontent.com/jamestheakston/unwire/main/install.sh | sudo bash
```

Running this command installs everything it needs, detects any printers already plugged in, and starts broadcasting them over AirPrint.

## What it does

- **Detects USB printers automatically**
- **Broadcasts AirPrint over the network**
- **Configures the best available driver**
- **Marks disconnected printers offline**
- **Serves a live status dashboard** at `http://unwire.local` showing every connected printer.
- **Proxies CUPS administration** at `http://admin.unwire.local` for advanced configuration.

## Requirements

- A supported Raspberry Pi (or any Debian/Ubuntu-based Linux box) running as root/sudo
- **The Pi must already be connected to the internet** (Wi-Fi or Ethernet) before running the installer — it downloads packages via `apt` during setup
- One or more USB printers
- A phone, tablet, or computer on the **same local network** as the Pi, to print and view the dashboard


## Recommended Hardware

Minimum: Raspberry Pi Zero 2 W <br>
Recommend: Raspberry Pi 3B+ or Raspberry Pi 4 (1GB)


## How it works

| Component | Purpose |
|---|---|
| `install.sh` | Installer — installs packages, configures CUPS/Nginx/Avahi, and deploys everything below |
| `src/cups-auto-add.sh` | Detects USB printers, creates CUPS queues, generates AirPrint service files |
| `src/update-printer-webpage.sh` | Regenerates the status dashboard at `/var/www/html/index.html` |
| `src/99-cups-autorun.rules` | udev rule that triggers instant detection on USB plug-in |
| `src/unwire-scan.service` / `src/unwire-scan.timer` | systemd timer that re-scans every 30 seconds, catching missed events and detecting unplugged printers |

Printers are named `[Printer Name] - Unwire` throughout — in the CUPS queue description, the AirPrint broadcast name, and the dashboard — so they're easy to spot in your printer picker.

## Accessing your printers

Your device must be connected to the **same local network** as the Pi (same Wi-Fi network, or same router) — Unwire only broadcasts on the local network, so it won't be reachable over cellular data or a different Wi-Fi network.

Once connected, on any Mac or iOS device:

1. Open **Print** from any app.
2. Select **Printer** → your printer should appear as `[Printer Name] - Unwire`.
3. Print — no drivers or setup required.

## Dashboard & admin

Open these from a device on the **same local network** as the Pi — they use `.local` addresses, which only resolve on your local network, not over the internet:

- **`http://unwire.local`** — live dashboard showing every connected printer and its status.
- **`http://admin.unwire.local`** — full CUPS web administration (add printers manually, view queues, manage jobs).

## Logs

Installation logs are written to `/var/log/unwire-install.log`. Runtime logs from the detection scripts are sent to syslog under the tags `unwire-auto-add` and `unwire-webpage` (view with `journalctl -t unwire-auto-add`).

## Uninstalling

```bash
sudo systemctl disable --now unwire-scan.timer
sudo rm -f /etc/systemd/system/unwire-scan.{service,timer}
sudo rm -f /etc/udev/rules.d/99-cups-autorun.rules
sudo rm -f /usr/local/bin/cups-auto-add.sh /usr/local/bin/update-printer-webpage.sh
sudo rm -f /etc/nginx/sites-enabled/unwire.conf /etc/nginx/sites-available/unwire.conf
sudo systemctl restart nginx
```

CUPS, Avahi, and Nginx themselves are left installed since other software may depend on them; remove with `apt remove` if no longer needed.

## License

See [LICENSE](LICENSE).