# Install & Disaster Recovery Guide

This guide covers installing the homeserver from scratch (bootstrapping), verifying your backups, restoring after a crash (disaster recovery) and replacing a failed disk.

---

## 1. First-time install (bootstrap)

### The fast path: the setup wizard

After completing **Step 1** and **Step 2** below, you can skip every other step by running the interactive wizard from the repository root:

```bash
./setup.sh
```

It connects to your server, detects your disks/timezone/user IDs, walks you through backups, VPN (OpenVPN or WireGuard) and optional services, generates all configuration files including the encrypted vault, and offers to deploy immediately. The manual steps below configure exactly the same things by hand.

Either way, finish with **[Step 8: Wire up the apps](#step-8-wire-up-the-apps-one-time-30-minutes)** — the one-time in-app configuration that connects qBittorrent, Prowlarr, the *arrs, Jellyfin and Jellyseerr together.

### Step 1: OS & network

1. Install a clean copy of **Debian** (or Ubuntu Server) on the server, with **at least 30 GB of OS disk space** — the container images alone take ~8 GB, and a full OS disk corrupts databases.
2. Make sure SSH access works and that your user has `sudo` rights.
3. Physically attach your data disk(s) — one is enough, more is fine. Format them (ext4 recommended) if they aren't already.
4. *(Optional)* attach a USB backup drive, or have credentials ready for a remote backup target (SFTP/S3/Backblaze B2).

> **Testing on a VM or cloud instance?** That works too (`hw_transcoding` switches off automatically): give the boot disk 30 GB and attach a couple of small extra disks as data disks. Two cloud gotchas: on GCP the guest agent may remove manually added `authorized_keys` entries — add your public key via the instance's SSH-keys metadata instead. And without a home LAN, set `lan_subnet` to the Tailscale range `100.64.0.0/10` so you can reach the WebUIs over Tailscale.

### Step 2: Prepare your control machine (laptop)

1. Install **Git** and **Ansible** on your laptop.
2. Clone this repository:
   ```bash
   git clone <your-repo-url>
   cd lean-mean-media-machine
   ```

### Step 3: Find your disk UUIDs

1. Log in to the new server over SSH.
2. Run the following command to list the UUIDs of your attached disks:
   ```bash
   sudo blkid
   ```
3. Note down the UUIDs of every data disk and (if you have one) the USB backup drive.

> **Tip:** using UUIDs (instead of `/dev/sdX`) means your mounts keep working even if Linux reorders the drive letters after a reboot.

### Step 4: Update the configuration

1. Open [ansible/inventory/hosts.yml](ansible/inventory/hosts.yml) and set the IP address (`ansible_host`) and username (`ansible_user`) of your server.
2. Open [ansible/inventory/group_vars/all.yml](ansible/inventory/group_vars/all.yml) and configure:

   **Storage** — list every data disk under `data_disks`, one entry per disk. This works for a single disk or for ten:
   ```yaml
   data_disks:
     - id: "UUID=your-real-uuid"
       path: "/mnt/disk1"
     # add more disks by adding more entries; optional per-disk 'fstype' (default ext4)
   ```

   *(Optional but recommended with 2+ data disks)* — protect your media against disk failure by dedicating one disk to `snapraid_parity_disks`. It must be at least as large as your largest data disk and must not be listed under `data_disks`. A failed data disk can then be rebuilt with `snapraid fix` instead of re-downloading everything.

   **Backups** — pick the option that matches your machine:
   - *USB drive:* set the UUID in `backup_usb` (the default `restic_repository` already points at it).
   - *Remote target:* remove the `backup_usb` block and set `restic_repository` to e.g. `sftp:user@nas:/backups/restic-repo` or `b2:bucket:repo`. Put the cloud credentials in `restic_env` (values in the vault).
   - *No backups:* set `backup_enabled: false`.

   **Backup monitoring (strongly recommended)** — create a free check at [healthchecks.io](https://healthchecks.io) and paste its ping URL into `backup_healthcheck_url`. You'll get an email whenever backups stop running. Without this, a broken backup goes unnoticed until the day you need it.

   **System watchdog (strongly recommended)** — create a *second* healthchecks.io check and paste its URL into `system_healthcheck_url`. A daily watchdog then reports disk space, disk health (SMART) and container state — so a filling pool or a dying disk becomes an email instead of an outage. The related `auto_reboot` setting (default on) reboots the server at 06:30 when a kernel update requires it.

   **Network** — set `lan_subnet` to your home network's subnet (e.g. `192.168.1.0/24`). This controls which network the firewall trusts and which subnet Gluetun allows to reach the WebUIs — get it wrong and the WebUIs will be unreachable from your LAN.

   **VPN** — the `gluetun_env` dict is passed 1:1 to the Gluetun container, so any provider/protocol from the [Gluetun wiki](https://github.com/qdm12/gluetun-wiki) works. The default block is OpenVPN (username/password); a commented WireGuard example (private key) is right below it. Using **ProtonVPN Free**? Add `FREE_ONLY: "on"` to the dict so Gluetun only selects free-tier servers — and use Proton's separate *OpenVPN credentials* from your account page, not your account password.

   **Optional services** — pick what you want in `compose_profiles`: `iptv` (Dispatcharr), `management` (Portainer), `logs` (Dozzle). Remove a profile and its container simply won't be deployed.

   **Hardware transcoding** — set `hw_transcoding: false` when deploying to a VM, a cloud instance or any machine without an Intel iGPU (the wizard detects this automatically). With it on, Jellyfin gets `/dev/dri` mapped for QuickSync.

   Also adjust `timezone` and `puid`/`pgid` if needed.

### Step 5: Create your secrets vault

The sensitive values (VPN, Tailscale, Restic) live in an encrypted vault file that is **git-ignored** — your secrets can never end up in a public repository. Create yours from the example:

```bash
cp ansible/inventory/group_vars/vault.yml.example ansible/inventory/group_vars/vault.yml
nano ansible/inventory/group_vars/vault.yml    # fill in your values
ansible-vault encrypt ansible/inventory/group_vars/vault.yml
```

(Edit it later with `ansible-vault edit ansible/inventory/group_vars/vault.yml`.)

Make sure it defines the keys your `gluetun_env` block references, plus Tailscale and Restic. For OpenVPN:

```yaml
vault_vpn_provider: "your-provider"      # e.g. mullvad, protonvpn, nordvpn
vault_vpn_user: "your-vpn-username"
vault_vpn_password: "your-vpn-password"
vault_tailscale_key: "tskey-auth-xxxx"   # from https://login.tailscale.com/admin/settings/keys
vault_restic_password: "a-strong-backup-password"
```

For WireGuard, replace `vault_vpn_user`/`vault_vpn_password` with:

```yaml
vault_wireguard_private_key: "your-wireguard-private-key"
vault_wireguard_addresses: "10.64.222.21/32"   # from your provider's WireGuard config
```

> **Keeping your own copy in Git?** In a *private* repository it's fine to version the encrypted vault — remove the `vault.yml` line from `.gitignore` there. Never do this in a public repository.

> ⚠️ **Store the vault password AND keep it recoverable.** The complete disaster-recovery chain is: Git repo + vault password + the Restic password inside the vault. If your house burns down and the vault password only existed on your laptop, your backups are permanently unrecoverable. Put the vault password in a password manager that syncs outside your home.

### Step 6: Save the vault password

Create a file named `.vault_pass` in the project root. It's already listed in `.gitignore`, so it will never be pushed to GitHub:

```bash
echo "YOUR_VAULT_PASSWORD" > .vault_pass
```

### Step 7: Run the playbook (deploy)

From your laptop, go into the `ansible` folder and start the deployment:

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file ../.vault_pass
```

Ansible now takes care of everything:

- Installing system updates and base packages, plus automatic security updates (`unattended-upgrades`) with an automatic reboot when a kernel patch requires it.
- Installing the daily system watchdog (disk space, SMART disk health, container state) and log rotation for the script logs.
- Mounting the disk(s) and configuring MergerFS at `/mnt/storage`.
- Installing and activating Tailscale (first run only — redeploys skip it).
- Enabling the UFW firewall (SSH allowed, LAN and Tailscale trusted, everything else denied).
- Installing the backup, restore and verification scripts and scheduling them via cron (daily backup at 04:00, weekly integrity check on Sunday at 06:00).
- Installing Docker (with log rotation) and bringing up the full media stack.

When it finishes, the infrastructure is done — continue with Step 8 to wire the apps together.

> ⚠️ **Do this now, or lose remote access in ~6 months:** Tailscale node keys **expire after 180 days** by default, after which the server silently drops off your tailnet. Open the [Tailscale admin console](https://login.tailscale.com/admin/machines), click the **⋯** menu next to your server and choose **Disable key expiry**. One click, and remote access keeps working for years.

### Step 8: Wire up the apps (one-time, ~30 minutes)

Everything is running, but the apps don't know each other yet. Walk through these once, in this order — afterwards the whole pipeline (request → download → library) is fully automatic. Replace `<server>` with your server's IP.

> **How the apps talk to each other:** inside the Docker network, containers reach each other by name (`radarr`, `jellyfin`, ...) — that's why you'll enter hostnames like `gluetun` below while using `<server>:port` in your own browser. qBittorrent is the special case: it lives inside Gluetun's network, so other apps reach it at `gluetun:8080`.

**1. qBittorrent — `http://<server>:8080`**

- ⚠️ **The login password is hidden in the container logs.** The LinuxServer image generates a temporary password on first start. Find it in Dozzle (`http://<server>:8888`, click the `qbittorrent` container) or on the server with `docker logs qbittorrent`. Log in as `admin` with that password.
- Set a permanent password: gear icon → **Options → WebUI → Authentication**.
- Set the download location: **Options → Downloads → Default Save Path** = `/data/torrents`. *This path is what makes instant hardlinks (and no double disk usage) work — don't skip it.*
- ⚠️ **Set seeding limits, or your disks fill up over time.** Without limits, every torrent seeds forever and `/data/torrents` grows until the pool is full. Go to **Options → BitTorrent → Seeding Limits** and set a ratio (e.g. `2`, or whatever your trackers require) with the action **Stop torrent**. Thanks to hardlinks, your media library keeps every file even after the torrent data is cleaned up.

**2. Prowlarr — `http://<server>:9696`** *(your indexer manager)*

- On first visit, set up authentication (Forms + a username/password).
- **Add your indexers/trackers** under **Indexers → Add Indexer**. This is the make-or-break step: without indexers, nothing can be found or downloaded.
- Connect the apps under **Settings → Apps → +**:
  - **Radarr**: Prowlarr server `http://prowlarr:9696`, Radarr server `http://radarr:7878`, API key from Radarr (**Settings → General → API Key**).
  - **Sonarr**: same, with `http://sonarr:8989` and Sonarr's API key.
- Prowlarr now pushes all your indexers to both apps automatically — you never configure indexers twice.

**3. Radarr — `http://<server>:7878`** *(movies)* **and Sonarr — `http://<server>:8989`** *(TV)*

Do this in both apps:

- Set up authentication on first visit.
- Root folder: **Settings → Media Management → Add Root Folder** → `/data/media/movies` (Radarr) / `/data/media/tv` (Sonarr).
- Download client: **Settings → Download Clients → + → qBittorrent** → host `gluetun`, port `8080`, and the username/password from step 1.

**4. Bazarr — `http://<server>:6767`** *(automatic subtitles in your language)*

- Set up authentication on first visit (**Settings → General → Security**).
- Create your language profile: **Settings → Languages** → add your language(s) under *Languages Filter* (e.g. **Dutch**, optionally English as fallback) → create a **Language Profile** with them → set it as the **default profile for both series and movies**.
- Add subtitle providers under **Settings → Providers → +** — for Dutch, [OpenSubtitles.com](https://www.opensubtitles.com) (free account) plus a few no-account providers like Podnapisi and Gestdown work well.
- Connect the *arrs: **Settings → Sonarr** → enable, host `sonarr`, port `8989`, its API key — and the same under **Settings → Radarr** with `radarr`, port `7878`.

From now on every new (and existing) download automatically gets subtitles in your chosen language, saved next to the media file — and Bazarr upgrades them later if a better match appears.

**5. Jellyfin — `http://<server>:8096`**

- Run the first-time wizard: create your admin account and add two libraries: **Movies** → `/data/media/movies` and **Shows** → `/data/media/tv`.
- Enable hardware transcoding: **Dashboard → Playback → Transcoding** → Hardware acceleration = **Intel QuickSync (QSV)**. The GPU device is already mapped into the container when `hw_transcoding` is on (the default on machines with an Intel iGPU — the wizard detects this automatically). On a VM or GPU-less machine, skip this step.
- *(Optional)* make subtitles appear automatically: per user under **Settings → Subtitles**, set *Preferred subtitle language* (e.g. Dutch) and *Subtitle mode* = **Default** — Jellyfin then auto-selects the subs Bazarr downloaded.

**6. Jellyseerr — `http://<server>:5055`** *(where you and your housemates request media)*

- Choose **Use your Jellyfin account**, Jellyfin URL `http://jellyfin:8096`, and sync the libraries.
- Under **Settings → Services**, add:
  - **Radarr**: hostname `radarr`, port `7878`, its API key, quality profile, root folder `/data/media/movies`, mark as default.
  - **Sonarr**: hostname `sonarr`, port `8989`, its API key, root folder `/data/media/tv`, mark as default.

**✅ Test the pipeline:** request a movie in Jellyseerr → Radarr grabs it via your Prowlarr indexers → qBittorrent downloads it to `/data/torrents` (through the VPN) → Radarr instantly hardlinks it into `/data/media/movies` → it appears in Jellyfin, and minutes later Bazarr adds subtitles in your language. If that works, you're done — everything from here on is automatic.

### Optional: auto-download trending content (Top 10 lists)

Radarr and Sonarr can automatically download whatever is trending on the big streaming services, using their built-in **Import Lists** — no extra software needed:

1. Find a list that tracks what you want: [Trakt](https://trakt.tv) and [mdblist.com](https://mdblist.com) host community-maintained, daily-updated lists such as *"Netflix Top 10"* (per country), *"Trending on Disney+"*, *"HBO Max Top 10"*, and many more.
2. In **Radarr → Settings → Import Lists → +**, add it (e.g. type *Trakt List*, or *Custom List* with the list URL). Set your quality profile, root folder `/data/media/movies`, and enable **Add & Monitor** + search on add.
3. Repeat in **Sonarr** for series, with root folder `/data/media/tv`.

From then on, anything that enters those charts shows up in Jellyfin automatically a few hours later.

> ⚠️ **Mind your disk space.** Several services × top-10 movies *and* series in 4K adds up to many terabytes, and the lists refresh continuously. Start with one or two lists and a modest quality profile (1080p) — the watchdog warns you at 90% full, but better not to get there.

> 💡 **Rotate instead of grow:** the *Clean Library Level* setting on each import list can automatically unmonitor (or even delete) items that drop off the chart, so your library mirrors the Top 10 instead of growing forever. Only use "Remove and Delete" if you're sure that's what you want.

---

## 2. Verify your backups (do this once!)

A restore you've never tested is a hope, not a plan. After your first backup has run (or trigger one manually with `sudo /opt/scripts/backup.sh`), rehearse the recovery **without touching your live data**:

```bash
# 1. Check that snapshots exist and the repository is healthy
sudo /opt/scripts/check.sh

# 2. Do a practice restore into a scratch directory
sudo /opt/scripts/restore.sh --test

# 3. Look around in /tmp/restore-test/opt/appdata — your configs should be there
sudo ls /tmp/restore-test/opt/appdata   # sudo: restic restores with the original (root) ownership

# 4. Clean up
sudo rm -rf /tmp/restore-test
```

If step 2 and 3 look good, your disaster recovery works. Repeat this once or twice a year.

---

## 3. Disaster recovery (restore)

If your server crashed and you've prepared a fresh Debian install, follow these steps to restore all your Docker data and configuration (appdata).

### Step 1: Redeploy the base

Follow **Step 1 through Step 7** of the first-time install above. This ensures the disks, MergerFS and Restic are set up correctly and that the restore script is present on the server.

> During the base deploy, the media stack will come up with empty configs. That's expected — you'll overwrite them from the backup in the next step.

### Step 2: Run the restore script

Log in to the server and run the generated restore script:

```bash
sudo /opt/scripts/restore.sh
```

*The script asks for confirmation, stops the stack, reads the most recent snapshot via Restic, and restores it into `/opt/appdata`.*

### Step 3: Reboot, or start the containers

Once the restore is complete, either reboot the server or bring the media stack back up directly:

```bash
docker compose --project-directory /opt/appdata up -d
```

Your media server is now fully restored and operational again.

---

## 4. Replacing a failed disk

Over the years a disk will die — the daily watchdog emails you when SMART reports a failing drive, or when a disk has dropped out. Nothing about this is an emergency: your appdata is in the backups, and the steps below get the media back too.

### A failed data disk

1. Physically replace the disk, format the new one (`sudo mkfs.ext4 /dev/sdX1`) and read its UUID with `sudo blkid`.
2. In `ansible/inventory/group_vars/all.yml`, replace the dead disk's UUID under `data_disks` with the new one (keep the same `path`).
3. Redeploy: the new disk is mounted and rejoins the MergerFS pool automatically.
   ```bash
   cd ansible && ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file ../.vault_pass
   ```
4. Get the data back:
   - **With SnapRAID parity:** rebuild the dead disk's contents onto the new one:
     ```bash
     sudo snapraid fix -d d1   # replace d1 with the disk's name from /etc/snapraid.conf
     ```
     The daily maintenance run takes over from there.
   - **Without parity:** the media on that disk is gone, but Radarr/Sonarr still know about every item. Select the missing items in each app and trigger a search — your library re-downloads itself over time.

### A failed backup drive

1. Replace the drive, format it, and update the UUID under `backup_usb` in `all.yml`.
2. Redeploy. The next backup run re-initialises the Restic repository automatically — but your old snapshots are gone, so trigger a fresh backup right away:
   ```bash
   sudo /opt/scripts/backup.sh
   ```

### A failed parity disk

1. Replace the drive, format it, and update the UUID under `snapraid_parity_disks` in `all.yml`.
2. Redeploy, then rebuild parity:
   ```bash
   sudo snapraid sync
   ```
