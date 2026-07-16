# Install & Disaster Recovery Guide

This guide covers installing the homeserver from scratch (bootstrapping) and restoring from a backup after a crash (disaster recovery).

---

## 1. First-time install (bootstrap)

Follow these steps to deploy the project on a brand-new server for the first time.

### Step 1: OS & network

1. Install a clean copy of **Debian** (or Ubuntu Server) on the Intel N100 machine.
2. Make sure SSH access works and that your user has `sudo` rights.
3. Physically attach the data disks and the USB backup drive. Format them as **ext4** if they aren't already.

### Step 2: Prepare your control machine (laptop)

1. Install **Git** and **Ansible** on your laptop.
2. Clone this repository:
   ```bash
   git clone <your-repo-url>
   cd homeserver-iac
   ```

### Step 3: Find your disk UUIDs

1. Log in to the new server over SSH.
2. Run the following command to list the UUIDs of your attached disks and USB drive:
   ```bash
   sudo blkid
   ```
3. Note down the UUIDs of the data disks (e.g. `/dev/sdb1`, `/dev/sdc1`) and of the USB backup drive.

> **Tip:** using UUIDs (instead of `/dev/sdX`) means your mounts keep working even if Linux reorders the drive letters after a reboot.

### Step 4: Update the configuration

1. Open [ansible/inventory/hosts.yml](ansible/inventory/hosts.yml) and set the IP address (`ansible_host`) and username (`ansible_user`) of your server.
2. Open [ansible/inventory/group_vars/all.yml](ansible/inventory/group_vars/all.yml) and:
   - Replace the example UUIDs under `data_disks` and `backup_usb` with your real ones.
   - Set `lan_subnet` to your home network's subnet (e.g. `192.168.1.0/24`). This controls which network the firewall trusts and which subnet Gluetun allows to reach the WebUIs — get it wrong and the WebUIs will be unreachable from your LAN.
   - Adjust `timezone` and `puid`/`pgid` if needed.

### Step 5: Add your secrets to the Ansible Vault

The sensitive values (VPN, Tailscale, Restic) are stored in an encrypted vault file. Edit it with:

```bash
ansible-vault edit ansible/inventory/group_vars/vault.yml
```

Make sure it defines all of these keys:

```yaml
vault_vpn_provider: "your-provider"      # e.g. mullvad, protonvpn, nordvpn
vault_vpn_user: "your-vpn-username"
vault_vpn_password: "your-vpn-password"
vault_tailscale_key: "tskey-auth-xxxx"   # from https://login.tailscale.com/admin/settings/keys
vault_restic_password: "a-strong-backup-password"
```

> If you are starting a brand-new vault, create it with `ansible-vault create ansible/inventory/group_vars/vault.yml` instead.
> **Do not lose `vault_restic_password`** — without it your backups cannot be decrypted or restored.

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

- Installing system updates and base packages (`mergerfs`, `restic`, `ufw`, `curl`, `git`).
- Mounting the disks and configuring MergerFS at `/mnt/storage`.
- Installing and activating Tailscale.
- Enabling the UFW firewall (SSH allowed, LAN and Tailscale trusted, everything else denied).
- Installing the backup scripts and scheduling them via cron.
- Installing Docker and bringing up the full media stack.

When it finishes, head to the [service list in the README](README.md#accessing-your-services) to log in to each app.

---

## 2. Disaster recovery (restore)

If your server crashed and you've prepared a fresh Debian install, follow these steps to restore all your Docker data and configuration (appdata).

### Step 1: Redeploy the base

1. Follow **Step 1 through Step 7** of the first-time install above. This ensures the disks, MergerFS and Restic are set up correctly and that the restore script is present on the server.

> During the base deploy, the media stack will come up with empty configs. That's expected — you'll overwrite them from the backup in the next steps.

### Step 2: Stop the Docker containers

Before overwriting the database and configuration files, stop the stack. Log in to the server and run:

```bash
docker stop jellyfin radarr sonarr prowlarr bazarr dispatcharr seerr qbittorrent || true
```

### Step 3: Run the restore script

Run the generated restore script on the server:

```bash
sudo /opt/scripts/restore.sh
```

*The script asks for confirmation, reads the most recent snapshot from your USB drive via Restic, and restores it into `/opt/appdata`.*

### Step 4: Reboot, or start the containers

Once the restore is complete, either reboot the server or bring the media stack back up directly:

```bash
cd /opt/appdata
docker compose up -d
```

Your media server is now fully restored and operational again.
