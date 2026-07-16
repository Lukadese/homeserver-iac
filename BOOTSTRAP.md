# Install & Disaster Recovery Guide

This guide covers installing the homeserver from scratch (bootstrapping), verifying your backups, and restoring after a crash (disaster recovery).

---

## 1. First-time install (bootstrap)

### The fast path: the setup wizard

After completing **Step 1** and **Step 2** below, you can skip every other step by running the interactive wizard from the repository root:

```bash
./setup.sh
```

It connects to your server, detects your disks/timezone/user IDs, walks you through backups, VPN (OpenVPN or WireGuard) and optional services, generates all configuration files including the encrypted vault, and offers to deploy immediately. The manual steps below configure exactly the same things by hand.

### Step 1: OS & network

1. Install a clean copy of **Debian** (or Ubuntu Server) on the server.
2. Make sure SSH access works and that your user has `sudo` rights.
3. Physically attach your data disk(s) — one is enough, more is fine. Format them (ext4 recommended) if they aren't already.
4. *(Optional)* attach a USB backup drive, or have credentials ready for a remote backup target (SFTP/S3/Backblaze B2).

### Step 2: Prepare your control machine (laptop)

1. Install **Git** and **Ansible** on your laptop.
2. Clone this repository:
   ```bash
   git clone <your-repo-url>
   cd homeserver-iac
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

   **Backups** — pick the option that matches your machine:
   - *USB drive:* set the UUID in `backup_usb` (the default `restic_repository` already points at it).
   - *Remote target:* remove the `backup_usb` block and set `restic_repository` to e.g. `sftp:user@nas:/backups/restic-repo` or `b2:bucket:repo`. Put the cloud credentials in `restic_env` (values in the vault).
   - *No backups:* set `backup_enabled: false`.

   **Backup monitoring (strongly recommended)** — create a free check at [healthchecks.io](https://healthchecks.io) and paste its ping URL into `backup_healthcheck_url`. You'll get an email whenever backups stop running. Without this, a broken backup goes unnoticed until the day you need it.

   **Network** — set `lan_subnet` to your home network's subnet (e.g. `192.168.1.0/24`). This controls which network the firewall trusts and which subnet Gluetun allows to reach the WebUIs — get it wrong and the WebUIs will be unreachable from your LAN.

   **VPN** — the `gluetun_env` dict is passed 1:1 to the Gluetun container, so any provider/protocol from the [Gluetun wiki](https://github.com/qdm12/gluetun-wiki) works. The default block is OpenVPN (username/password); a commented WireGuard example (private key) is right below it.

   **Optional services** — pick what you want in `compose_profiles`: `iptv` (Dispatcharr), `management` (Portainer), `logs` (Dozzle). Remove a profile and its container simply won't be deployed.

   Also adjust `timezone` and `puid`/`pgid` if needed.

### Step 5: Add your secrets to the Ansible Vault

The sensitive values (VPN, Tailscale, Restic) are stored in an encrypted vault file. Edit it with:

```bash
ansible-vault edit ansible/inventory/group_vars/vault.yml
```

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

> If you are starting a brand-new vault, create it with `ansible-vault create ansible/inventory/group_vars/vault.yml` instead.

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

- Installing system updates and base packages, plus automatic security updates (`unattended-upgrades`).
- Mounting the disk(s) and configuring MergerFS at `/mnt/storage`.
- Installing and activating Tailscale (first run only — redeploys skip it).
- Enabling the UFW firewall (SSH allowed, LAN and Tailscale trusted, everything else denied).
- Installing the backup, restore and verification scripts and scheduling them via cron (daily backup at 04:00, weekly integrity check on Sunday at 05:00).
- Installing Docker (with log rotation) and bringing up the full media stack.

When it finishes, head to the [service list in the README](README.md#accessing-your-services) to log in to each app.

---

## 2. Verify your backups (do this once!)

A restore you've never tested is a hope, not a plan. After your first backup has run (or trigger one manually with `sudo /opt/scripts/backup.sh`), rehearse the recovery **without touching your live data**:

```bash
# 1. Check that snapshots exist and the repository is healthy
sudo /opt/scripts/check.sh

# 2. Do a practice restore into a scratch directory
sudo /opt/scripts/restore.sh --test

# 3. Look around in /tmp/restore-test/opt/appdata — your configs should be there
ls /tmp/restore-test/opt/appdata

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
