# Lean Mean Media Machine

[![CI](https://github.com/Lukadese/lean-mean-media-machine/actions/workflows/ci.yml/badge.svg)](https://github.com/Lukadese/lean-mean-media-machine/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Lukadese/lean-mean-media-machine)](https://github.com/Lukadese/lean-mean-media-machine/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A GitOps-based Infrastructure-as-Code setup for a fully automated, power-efficient 4K media server. Built and tuned on a low-power **Intel N100** box (comfortably handles up to ~4 simultaneous 4K viewers), but generic enough for any Debian machine — one disk or many, with or without a backup drive.

Everything — the OS, disks, networking, containers and backups — is described in Ansible. You make changes in Git and roll them out with a single command. No manual clicking on the server.

---

## Table of Contents

- [What you get](#what-you-get)
- [The stack](#the-stack)
- [How it works](#how-it-works)
- [Storage & data layout](#storage--data-layout)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Accessing your services](#accessing-your-services)
- [First-run configuration](#first-run-configuration)
- [Backups & disaster recovery](#backups--disaster-recovery)
- [Running it for years](#running-it-for-years)
- [Image versioning](#image-versioning)
- [Repository layout](#repository-layout)
- [Contributing & support](#contributing--support)
- [Legal](#legal)
- [License](#license)

---

## What you get

- **100% GitOps & IaC** — the complete server configuration (OS, disks, network, containers, backups) lives in Ansible playbooks. Change it in Git, deploy it centrally.
- **Intel QuickSync hardware transcoding** — full hardware H.265/HEVC transcoding via the `/dev/dri` GPU mapping in Jellyfin, so the CPU stays cool and idle.
- **Storage pooling with MergerFS** — any number of data disks (one or many) is transparently combined into one virtual pool at `/mnt/storage`, without RAID overhead. Add a disk by adding one entry to a list.
- **Optional SnapRAID parity** — dedicate one disk as parity and a failed data disk can be *rebuilt* instead of re-downloaded, with a daily sync + scrub guarding against silent bit rot. One list in `all.yml` turns it on.
- **TRaSH Guides-compliant layout** — a single shared `data` mount enables instant **hardlinks (atomic moves)** between qBittorrent and Radarr/Sonarr, avoiding a second copy and unnecessary disk wear.
- **VPN kill switch via Gluetun** — qBittorrent and Dispatcharr route *all* their traffic through the Gluetun VPN container. If the VPN drops, Gluetun blocks all traffic instantly. Works with **any Gluetun-supported provider, over OpenVPN or WireGuard**.
- **Guided setup wizard** — `./setup.sh` detects your server's disks and settings over SSH and generates the entire configuration interactively, encrypted vault included.
- **Modular services** — optional components (IPTV, Portainer, Dozzle) are toggled with a single `compose_profiles` list.
- **Automated encrypted backups** — daily incremental, encrypted Restic backups of `/opt/appdata` to a USB drive **or any Restic backend** (SFTP, S3, Backblaze B2, ...), scheduled via cron. Weekly integrity checks and optional failure alerts via a free [healthchecks.io](https://healthchecks.io) ping. Backups can also be disabled entirely on machines without a backup target.
- **Rehearsable disaster recovery** — a generated restore script with a `--test` mode, so you can practice a full recovery without touching your live data.
- **Remote access via Tailscale** — reach every service securely over your own private WireGuard mesh network, no port forwarding required.
- **Firewall out of the box** — UFW is enabled with a sane default: SSH is allowed (rate-limited), the LAN and Tailscale are trusted, everything else inbound is denied.
- **Zero-touch OS maintenance** — automatic security updates via `unattended-upgrades` (including the reboot kernel patches need, scheduled after the backup window), Docker log rotation and log cleanup, so the server keeps itself healthy between deploys.
- **A watchdog that emails you before things break** — a daily check of disk space, disk health (SMART) and container state, reporting to a free healthchecks.io check. A dying disk becomes an alert, not a surprise.

---

## The stack

| Category | Services |
|----------|----------|
| **Media & automation** | Jellyfin, Radarr, Sonarr, Prowlarr, Bazarr, Jellyseerr |
| **Downloaders** | qBittorrent, Dispatcharr (IPTV, *optional*) |
| **Management & monitoring** | Portainer (*optional*), Dozzle (live log viewer, *optional*) |
| **Network & security** | Gluetun (VPN kill switch), Tailscale (mesh VPN), UFW (firewall) |

Optional services are enabled or disabled with the `compose_profiles` list in `all.yml` — no compose editing needed.

---

## How it works

```text
                        Internet
                           │
              ┌────────────┴────────────┐
              │      Gluetun (VPN)       │  ← kill switch: no VPN = no traffic
              │  qBittorrent  Dispatcharr│
              └────────────┬────────────┘
                           │ hardlinks (same filesystem)
   ┌───────────────────────┴───────────────────────┐
   │  MergerFS pool  →  /mnt/storage/data           │
   │     ├── torrents/   (qBittorrent downloads)    │
   │     └── media/      (Jellyfin library)         │
   └───────────────────────┬───────────────────────┘
                           │
   Radarr / Sonarr / Prowlarr / Bazarr / Jellyseerr
                           │
                       Jellyfin  ← Intel QuickSync HW transcoding
```

- **qBittorrent and Dispatcharr have no network of their own** — they use `network_mode: service:gluetun`, so every packet leaves through the VPN. They start only once Gluetun reports healthy.
- **Downloads and the media library share one filesystem** (`/mnt/storage/data`), so Radarr/Sonarr move finished downloads to the library with an instant hardlink instead of a slow copy.
- **Jellyfin gets the iGPU** via `/dev/dri` plus the `render`/`video` groups, enabling QuickSync hardware transcoding.
- **Remote access is Tailscale-only** — you don't expose any ports to the internet.

---

## Storage & data layout

The data disks are combined with MergerFS — this works identically for a single disk or for many, so the same setup runs on a tiny one-disk box and on a large multi-bay server. The directory tree under `/mnt/storage` follows the TRaSH Guides so the *arr apps work optimally:

```text
/mnt/storage/
└── data/
    ├── torrents/          # qBittorrent download folder
    │   ├── movies/
    │   └── tv/
    └── media/             # Jellyfin library (hardlinked from torrents)
        ├── movies/
        └── tv/
```

Both `torrents/` and `media/` live under the **same** `data/` mount. That shared parent is what makes hardlinks possible — keep it that way.

---

## Requirements

**On the server (the machine that runs everything):**

- A clean **Debian** (or Ubuntu Server) install on your Intel N100 box.
- SSH access, and a user with `sudo` rights.
- **One or more data disks**, physically attached and formatted (ext4 by default; other filesystems are configurable per disk).
- *(Optional)* a USB backup drive — or credentials for a remote backup target (SFTP/S3/B2). You can also run without backups entirely.

**On your control machine (your laptop):**

- **Git** and **Ansible** installed.
- The vault password for this repository (see [Quick start](#quick-start), step 4).

**Accounts / keys you'll need:**

- Credentials for a [Gluetun-supported VPN provider](https://github.com/qdm12/gluetun-wiki) — OpenVPN (username/password) or WireGuard (private key) both work.
- A [Tailscale auth key](https://login.tailscale.com/admin/settings/keys).

---

## Quick start

> **Using this project for your own server?** Click **"Use this template"** on GitHub (or fork it) to get your own copy first — that's where your personal configuration will live. Keep your copy **private** if you plan to commit your encrypted vault to it.

### The easy way: the setup wizard (recommended)

On your laptop (Linux/macOS/WSL — the same place Ansible runs):

```bash
git clone https://github.com/<your-username>/<your-copy>.git
cd <your-copy>
./setup.sh
```

The wizard connects to your server over SSH, **detects your disks, timezone and user IDs automatically**, asks a handful of questions (which disks to pool, how to back up, which VPN), generates all configuration — including the encrypted vault — and offers to deploy immediately. From blank server to running media stack in one sitting, no YAML editing required.

### The manual way

> Prefer to configure by hand, or want to understand what the wizard does? For a fully detailed walkthrough see **[BOOTSTRAP.md](BOOTSTRAP.md)**.

**1. Clone your copy of the repository (on your laptop):**

```bash
git clone https://github.com/<your-username>/<your-copy>.git
cd <your-copy>
```

**2. Point Ansible at your server** — edit [`ansible/inventory/hosts.yml`](ansible/inventory/hosts.yml) and set `ansible_host` (your server's IP) and `ansible_user` (your sudo user).

**3. Configure your disks, backups and network** — edit [`ansible/inventory/group_vars/all.yml`](ansible/inventory/group_vars/all.yml):

- List your disks under `data_disks` — one entry per disk, whether you have one or ten (run `sudo blkid` on the server to find the UUIDs).
- Configure backups: point `backup_usb` at your USB drive, **or** set `restic_repository` to a remote target (SFTP/S3/B2), **or** set `backup_enabled: false` to skip backups.
- *(Recommended)* paste a free [healthchecks.io](https://healthchecks.io) ping URL into `backup_healthcheck_url` so you get an email when backups stop working — and a second one into `system_healthcheck_url` for the daily watchdog (disk space, disk health, containers).
- Set `lan_subnet` to your home network's subnet (e.g. `192.168.1.0/24`). **This matters:** it's what lets you reach the WebUIs from your LAN and keeps SSH open through the firewall.
- Configure the VPN in `gluetun_env` — the default block is OpenVPN; a WireGuard example is included. Any [Gluetun-supported provider/protocol](https://github.com/qdm12/gluetun-wiki) works.
- Pick your optional services in `compose_profiles` (`iptv` = Dispatcharr, `management` = Portainer, `logs` = Dozzle).
- Adjust `timezone`, `puid`/`pgid` if needed.

**4. Create your secrets vault** — copy the example, fill in your values, and encrypt it:

```bash
cp ansible/inventory/group_vars/vault.yml.example ansible/inventory/group_vars/vault.yml
nano ansible/inventory/group_vars/vault.yml
ansible-vault encrypt ansible/inventory/group_vars/vault.yml
```

It must define the keys referenced by your `gluetun_env` block, plus Tailscale and Restic. For OpenVPN:

```yaml
vault_vpn_provider: "your-provider"      # e.g. mullvad, protonvpn, nordvpn
vault_vpn_user: "your-vpn-username"
vault_vpn_password: "your-vpn-password"
vault_tailscale_key: "tskey-auth-xxxx"
vault_restic_password: "a-strong-backup-password"
```

For WireGuard, replace the user/password keys with `vault_wireguard_private_key` and `vault_wireguard_addresses` (and switch `gluetun_env` to the WireGuard example in `all.yml`).

**5. Save your vault password** — create a `.vault_pass` file in the project root (already git-ignored, so it never reaches GitHub):

```bash
echo "YOUR_VAULT_PASSWORD" > .vault_pass
```

**6. Deploy:**

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file ../.vault_pass
```

Ansible now does everything: system updates, base packages, disk mounting + MergerFS, Tailscale, the firewall, the backup schedule, Docker, and the full media stack. When it finishes, your server is live — finish with the one-time [First-run configuration](#first-run-configuration) to connect the apps to each other.

---

## Accessing your services

After deployment, browse to your server's IP (on your LAN or over Tailscale) on these ports:

| Service | Port | URL |
|---------|------|-----|
| Jellyfin | 8096 | `http://<server>:8096` |
| Jellyseerr (requests) | 5055 | `http://<server>:5055` |
| Radarr (movies) | 7878 | `http://<server>:7878` |
| Sonarr (TV) | 8989 | `http://<server>:8989` |
| Prowlarr (indexers) | 9696 | `http://<server>:9696` |
| Bazarr (subtitles) | 6767 | `http://<server>:6767` |
| qBittorrent | 8080 | `http://<server>:8080` |
| Dispatcharr (IPTV, optional) | 8000 | `http://<server>:8000` |
| Portainer (optional) | 9443 | `https://<server>:9443` |
| Dozzle (logs, optional) | 8888 | `http://<server>:8888` |

> qBittorrent and Dispatcharr are served *through* Gluetun. If a WebUI is unreachable from your LAN, double-check that `lan_subnet` in `all.yml` matches your actual network.

---

## First-run configuration

After the deploy everything is *running*, but the apps don't know each other yet. One guided, one-time walkthrough (~30 minutes) connects them: qBittorrent's hidden first-run password and save path, your indexers in Prowlarr, the download client and root folders in Radarr/Sonarr, Jellyfin's libraries + QuickSync, and Jellyseerr on top. After that, requesting a movie in Jellyseerr makes it appear in Jellyfin fully automatically.

👉 **Follow [Step 8: Wire up the apps in BOOTSTRAP.md](BOOTSTRAP.md#step-8-wire-up-the-apps-one-time-30-minutes)** — every click is written out, including the gotchas.

**Pro tip — HEVC/x265 without transcoding:** once the apps are connected, import the TRaSH Guides Custom Formats for `HEVC/x265` in Radarr and Sonarr and give them a score of e.g. `+100`. Your download client then grabs compact, pre-compressed files that play directly on capable clients — so your N100 barely has to transcode at all.

**Pro tip — auto-download trending content:** Radarr/Sonarr's built-in Import Lists can automatically grab whatever is in the Top 10 on Netflix, Disney+, HBO Max & co, and even rotate your library along with the charts — see [the guide in BOOTSTRAP.md](BOOTSTRAP.md#optional-auto-download-trending-content-top-10-lists).

---

## Backups & disaster recovery

- **What is backed up:** `/opt/appdata` (all your container configs and databases). Your media itself is *not* backed up — it's reproducible via the *arr apps.
- **When:** every day at 04:00 (backup) and every Sunday at 06:00 (repository integrity check), via cron.
- **Where:** any Restic backend — a local USB drive, SFTP, S3, Backblaze B2, ... configured with the `restic_repository` variable. For real disaster resilience (fire, theft, power surge), prefer a remote target or combine both.
- **How:** Restic, encrypted, incremental. Retention: 7 daily + 4 weekly + 6 monthly snapshots.
- **Consistency:** the stack is stopped during the backup and restarted afterwards — even if the backup fails halfway.
- **Monitoring:** set `backup_healthcheck_url` and you'll be alerted automatically when backups stop running or the repository fails its weekly check. **A backup that isn't monitored will fail silently, exactly when you need it.**

**Practice your recovery** (recommended after your first backup — a restore you've never tested is a hope, not a plan):

```bash
sudo /opt/scripts/restore.sh --test   # restores to /tmp/restore-test, touches nothing
```

To restore for real after a crash, redeploy with the playbook and run:

```bash
sudo /opt/scripts/restore.sh
```

> ⚠️ **Guard your two recovery keys.** Everything can be rebuilt from Git **plus** your vault password (unlocks the secrets) **plus** the Restic password inside the vault (unlocks the backups). Store the vault password in a password manager that lives outside your house (e.g. a cloud-synced password manager). If both your laptop and server are lost and you don't have the vault password, your backups are unrecoverable — by design.

Full step-by-step recovery instructions are in **[BOOTSTRAP.md](BOOTSTRAP.md#3-disaster-recovery-restore)**.

---

## Running it for years

This project is built to run unattended — but "zero maintenance" software doesn't exist, so here is the honest split:

| The server handles by itself | What's left for you |
|---|---|
| Security updates, including the reboot kernel patches need | **Monthly (~5 min):** rerun the playbook — see below |
| Daily encrypted backups + weekly integrity checks | **Yearly:** rehearse a restore: `sudo /opt/scripts/restore.sh --test` |
| Daily watchdog: disk space, disk health (SMART), containers | **Every ~2 years:** upgrade Debian to the new stable release, then rerun the playbook |
| VPN server-list refresh, SnapRAID sync/scrub, log rotation | **When an alert email arrives:** read it — it says exactly what's wrong |

**The monthly playbook run is the one habit that matters:**

```bash
cd ansible && ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file ../.vault_pass
```

It patches the OS and pulls the latest version of every container. Monthly means small, low-risk version steps. Skipping it for a year means jumping every app across many major versions at once — the riskiest way to update anything. Put a recurring reminder in your calendar; it's five minutes, usually less.

**When a disk dies** — and over the years, one will — the watchdog emails you. Your appdata is covered by the backups, and with [SnapRAID parity](#what-you-get) even the media on the dead disk survives. Follow the [disk replacement runbook in BOOTSTRAP.md](BOOTSTRAP.md#4-replacing-a-failed-disk).

---

## Image versioning

All containers deliberately run on the `:latest` tag and are pulled on every deploy (`pull: always`). This keeps the stack automatically up to date and maximally plug-and-play. The trade-off: a deploy is not 100% reproducible, and a breaking upstream image update could disrupt something on the next deploy. If you want more control, pin a specific version tag per service in [`compose/docker-compose.yml`](compose/docker-compose.yml) and rely on the Restic backups to roll back.

---

## Repository layout

```text
.
├── setup.sh                        # interactive setup wizard (the recommended way in)
├── ansible/
│   ├── ansible.cfg
│   ├── site.yml                    # top-level playbook (base → docker → media_stack)
│   ├── inventory/
│   │   ├── hosts.yml               # your server's IP and user
│   │   └── group_vars/
│   │       ├── all.yml             # disks, backups, VPN, profiles, non-secret config
│   │       └── vault.yml.example   # template for your encrypted secrets
│   │                               # (your real vault.yml is git-ignored)
│   └── roles/
│       ├── base/                   # updates, packages, disks, MergerFS, Tailscale, UFW,
│       │                           # auto updates/reboots, watchdog, backup/restore scripts
│       ├── snapraid/               # optional parity protection (sync + scrub)
│       ├── docker/                 # Docker engine + Compose plugin + log rotation
│       └── media_stack/            # renders .env + gluetun.env, deploys compose, starts stack
├── compose/
│   └── docker-compose.yml          # the full service definition
├── .github/workflows/ci.yml        # lints Ansible + validates compose on every push
├── BOOTSTRAP.md                    # detailed install & disaster-recovery guide
└── README.md
```

---

## Contributing & support

- ❓ **Questions or setup help** → [Discussions](../../discussions)
- 🐛 **Bugs & feature requests** → [Issues](../../issues)
- 🔧 **Want to contribute?** → see [CONTRIBUTING.md](CONTRIBUTING.md) — PRs are very welcome

---

## Legal

This project is an automation template for self-hosting your own media. It downloads nothing by itself. You are responsible for what you download and share with it — only use it for content you have the rights to. The VPN integration exists to protect your privacy, not to enable infringement.

---

## License

Released under the [MIT License](LICENSE).
