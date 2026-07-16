#!/usr/bin/env bash
#
# Interactive setup wizard for the Lean Mean Media Machine.
#
# Run this from the repository root on your control machine (Linux/macOS/WSL):
#   ./setup.sh
#
# It connects to your server over SSH, detects your disks, timezone and user
# IDs, asks a handful of questions, and generates:
#   - ansible/inventory/hosts.yml
#   - ansible/inventory/group_vars/all.yml
#   - ansible/inventory/group_vars/vault.yml  (encrypted)
#   - .vault_pass
#
# Existing files are backed up with a .bak suffix before being overwritten.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INV_DIR="$REPO_DIR/ansible/inventory"
HOSTS_FILE="$INV_DIR/hosts.yml"
ALL_FILE="$INV_DIR/group_vars/all.yml"
VAULT_FILE="$INV_DIR/group_vars/vault.yml"
VAULT_PASS_FILE="$REPO_DIR/.vault_pass"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null 2>&1 || die "ssh is required on this machine."
command -v ansible-vault >/dev/null 2>&1 || die "ansible-vault not found — install Ansible first (e.g. 'pipx install ansible' or 'apt install ansible')."

# --- small input helpers -----------------------------------------------------

ask() { # ask "Question" ["default"] -> $REPLY
  local q="$1" def="${2:-}"
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " REPLY
    REPLY="${REPLY:-$def}"
  else
    while true; do
      read -r -p "$q: " REPLY
      [[ -n "$REPLY" ]] && break
    done
  fi
}

ask_secret() { # hidden input -> $REPLY
  local q="$1"
  while true; do
    read -r -s -p "$q: " REPLY
    echo
    [[ -n "$REPLY" ]] && break
  done
}

ask_yn() { # ask_yn "Question" "y"|"n" -> exit status
  local q="$1" def="${2:-n}" hint a
  [[ "$def" == "y" ]] && hint="Y/n" || hint="y/N"
  read -r -p "$q [$hint]: " a
  a="${a:-$def}"
  [[ "$a" =~ ^[Yy] ]]
}

gen_secret() {
  dd if=/dev/urandom bs=48 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32
}

backup_file() {
  [[ -f "$1" ]] && cp -f "$1" "$1.bak" && info "Backed up existing $(basename "$1") to $(basename "$1").bak"
  return 0
}

# --- 1. server connection ----------------------------------------------------

bold "Step 1/6 — Server connection"
ask "Server IP address (e.g. 192.168.1.50)"
SERVER_IP="$REPLY"
ask "SSH user on the server (needs sudo rights)"
SSH_USER="$REPLY"
TARGET="$SSH_USER@$SERVER_IP"

info "Testing SSH connection and reading server facts (you may be asked for your SSH password)..."
FACTS="$(ssh -o ConnectTimeout=10 "$TARGET" bash -s <<'EOS'
echo "FACT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Europe/Brussels)"
echo "FACT_PUID=$(id -u)"
echo "FACT_PGID=$(id -g)"
echo "---DISKS---"
lsblk -P -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT,TYPE
EOS
)" || die "Could not connect to $TARGET over SSH."

FACT_TZ="$(sed -n 's/^FACT_TZ=//p' <<<"$FACTS")"
FACT_PUID="$(sed -n 's/^FACT_PUID=//p' <<<"$FACTS")"
FACT_PGID="$(sed -n 's/^FACT_PGID=//p' <<<"$FACTS")"
info "Connected. Detected timezone: $FACT_TZ, user id: $FACT_PUID, group id: $FACT_PGID"

# --- 2. disks ----------------------------------------------------------------

bold "Step 2/6 — Disks"

# Collect candidate filesystems: partitions/disks with a UUID that are not the
# OS filesystem, boot partitions or swap.
DISK_NAME=() DISK_SIZE=() DISK_FSTYPE=() DISK_UUID=() DISK_MOUNT=()
while IFS= read -r line; do
  NAME="" SIZE="" FSTYPE="" UUID="" MOUNTPOINT="" TYPE=""
  eval "$line"
  [[ -z "$UUID" || -z "$FSTYPE" ]] && continue
  [[ "$FSTYPE" == "swap" || "$FSTYPE" == "squashfs" ]] && continue
  case "$MOUNTPOINT" in
    "/" | /boot* | "[SWAP]") continue ;;
  esac
  DISK_NAME+=("$NAME"); DISK_SIZE+=("$SIZE"); DISK_FSTYPE+=("$FSTYPE")
  DISK_UUID+=("$UUID"); DISK_MOUNT+=("$MOUNTPOINT")
done < <(sed -n '/^---DISKS---$/,$p' <<<"$FACTS" | tail -n +2)

[[ ${#DISK_NAME[@]} -gt 0 ]] || die "No usable filesystems found on the server. Format your data disk(s) first (e.g. 'sudo mkfs.ext4 /dev/sdX1')."

echo "Filesystems found on the server:"
for i in "${!DISK_NAME[@]}"; do
  printf '  %d) %-8s %-8s %-6s UUID=%s %s\n' "$((i + 1))" "${DISK_NAME[$i]}" "${DISK_SIZE[$i]}" "${DISK_FSTYPE[$i]}" "${DISK_UUID[$i]}" "${DISK_MOUNT[$i]:+(currently mounted at ${DISK_MOUNT[$i]})}"
done

DATA_SEL=()
while [[ ${#DATA_SEL[@]} -eq 0 ]]; do
  ask "Which are your DATA disks? Enter numbers separated by spaces (e.g. \"1 3\")"
  for n in $REPLY; do
    [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#DISK_NAME[@]})) && DATA_SEL+=("$((n - 1))") || { warn "Invalid selection: $n"; DATA_SEL=(); break; }
  done
done

DATA_DISKS_YAML=""
idx=1
for i in "${DATA_SEL[@]}"; do
  DATA_DISKS_YAML+="  - id: \"UUID=${DISK_UUID[$i]}\"\n"
  DATA_DISKS_YAML+="    path: \"/mnt/disk${idx}\"\n"
  [[ "${DISK_FSTYPE[$i]}" != "ext4" ]] && DATA_DISKS_YAML+="    fstype: ${DISK_FSTYPE[$i]}\n"
  idx=$((idx + 1))
done

PARITY_YAML="snapraid_parity_disks: []\n"
echo "Optional: dedicate one disk as SnapRAID parity — it lets you rebuild a failed"
echo "data disk instead of re-downloading everything. It must be at least as large"
echo "as your largest data disk, empty, and NOT one of the data disks you selected."
read -r -p "Which number is a PARITY disk? (leave empty to skip): " pn
if [[ -n "$pn" ]]; then
  [[ "$pn" =~ ^[0-9]+$ ]] && ((pn >= 1 && pn <= ${#DISK_NAME[@]})) || die "Invalid disk number: $pn"
  p=$((pn - 1))
  PARITY_YAML="snapraid_parity_disks:\n  - id: \"UUID=${DISK_UUID[$p]}\"\n    path: \"/mnt/parity1\"\n"
  [[ "${DISK_FSTYPE[$p]}" != "ext4" ]] && PARITY_YAML+="    fstype: ${DISK_FSTYPE[$p]}\n"
fi

# --- 3. backups --------------------------------------------------------------

bold "Step 3/6 — Backups"
BACKUP_ENABLED="true"
BACKUP_USB_YAML=""
RESTIC_REPO="/mnt/usb-backup/restic-repo"
HEALTHCHECK_URL=""

echo "Backup options:"
echo "  1) Local drive (USB/extra disk attached to the server)"
echo "  2) Remote Restic repository (SFTP / S3 / Backblaze B2 / ...)"
echo "  3) No backups (not recommended)"
ask "Choose a backup option" "1"
case "$REPLY" in
  1)
    ask "Which number in the disk list above is the BACKUP drive?"
    n="$REPLY"
    [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#DISK_NAME[@]})) || die "Invalid disk number: $n"
    b=$((n - 1))
    BACKUP_USB_YAML="backup_usb:\n  id: \"UUID=${DISK_UUID[$b]}\"\n  path: \"/mnt/usb-backup\"\n"
    [[ "${DISK_FSTYPE[$b]}" != "ext4" ]] && BACKUP_USB_YAML+="  fstype: ${DISK_FSTYPE[$b]}\n"
    ;;
  2)
    ask "Restic repository URL (e.g. sftp:user@nas:/backups/restic-repo or b2:bucket:repo)"
    RESTIC_REPO="$REPLY"
    warn "Cloud backends need credentials: add them to 'restic_env' in all.yml after this wizard (values in the vault)."
    ;;
  3)
    BACKUP_ENABLED="false"
    warn "Backups disabled — a crash means starting your app configuration from scratch."
    ;;
  *) die "Invalid choice." ;;
esac

if [[ "$BACKUP_ENABLED" == "true" ]]; then
  echo "Strongly recommended: create a free check at https://healthchecks.io and paste"
  echo "its ping URL here — you'll get an email whenever backups stop working."
  read -r -p "Healthcheck ping URL (leave empty to skip): " HEALTHCHECK_URL
fi

# --- 4. network & services ---------------------------------------------------

bold "Step 4/6 — Network & optional services"
SUBNET_SUGGESTION="${SERVER_IP%.*}.0/24"
ask "Your LAN subnet" "$SUBNET_SUGGESTION"
LAN_SUBNET="$REPLY"

echo "A daily watchdog checks disk space, disk health (SMART) and containers."
echo "Give it its own healthchecks.io ping URL (separate from the backup one)"
echo "to get alerted when something needs attention."
read -r -p "System watchdog ping URL (leave empty to skip): " WATCHDOG_URL

PROFILES=()
ask_yn "Enable IPTV (Dispatcharr)?" "n" && PROFILES+=("iptv")
ask_yn "Enable Portainer (container management UI)?" "y" && PROFILES+=("management")
ask_yn "Enable Dozzle (live log viewer)?" "y" && PROFILES+=("logs")
PROFILES_YAML="[$(IFS=', '; echo "${PROFILES[*]:-}")]"

# --- 5. secrets --------------------------------------------------------------

bold "Step 5/6 — VPN, Tailscale & passwords"
ask "VPN provider (as named in the Gluetun wiki, e.g. mullvad, protonvpn, nordvpn)"
VPN_PROVIDER="$REPLY"

echo "VPN protocol:  1) OpenVPN (username/password)   2) WireGuard (private key)"
ask "Choose your VPN protocol" "1"
if [[ "$REPLY" == "2" ]]; then
  VPN_TYPE="wireguard"
  ask_secret "WireGuard private key"
  WG_KEY="$REPLY"
  ask "WireGuard address(es), from your provider's config (e.g. 10.64.222.21/32)"
  WG_ADDR="$REPLY"
else
  VPN_TYPE="openvpn"
  ask "VPN username"
  VPN_USER="$REPLY"
  ask_secret "VPN password"
  VPN_PASS="$REPLY"
fi

echo "Create a Tailscale auth key at https://login.tailscale.com/admin/settings/keys"
ask_secret "Tailscale auth key (tskey-auth-...)"
TS_KEY="$REPLY"

GENERATED_SECRETS=""
if ask_yn "Generate a strong Restic backup password for you?" "y"; then
  RESTIC_PASS="$(gen_secret)"
  GENERATED_SECRETS+="  Restic backup password: $RESTIC_PASS\n"
else
  ask_secret "Restic backup password"
  RESTIC_PASS="$REPLY"
fi

if [[ -f "$VAULT_PASS_FILE" ]]; then
  info "Using the existing .vault_pass file."
  VAULT_PASS="$(cat "$VAULT_PASS_FILE")"
elif ask_yn "Generate a vault password for you?" "y"; then
  VAULT_PASS="$(gen_secret)"
  GENERATED_SECRETS+="  Ansible vault password: $VAULT_PASS\n"
else
  ask_secret "Vault password"
  VAULT_PASS="$REPLY"
fi

# --- 6. write everything -----------------------------------------------------

bold "Step 6/6 — Writing configuration"

backup_file "$HOSTS_FILE"
cat > "$HOSTS_FILE" <<EOF
all:
  children:
    homeservers:
      hosts:
        mediaserver:
          ansible_host: $SERVER_IP
          ansible_user: $SSH_USER
EOF
info "Wrote $HOSTS_FILE"

if [[ "$VPN_TYPE" == "wireguard" ]]; then
  GLUETUN_YAML="gluetun_env:\n  VPN_SERVICE_PROVIDER: \"{{ vault_vpn_provider }}\"\n  VPN_TYPE: \"wireguard\"\n  WIREGUARD_PRIVATE_KEY: \"{{ vault_wireguard_private_key }}\"\n  WIREGUARD_ADDRESSES: \"{{ vault_wireguard_addresses }}\"\n  UPDATER_PERIOD: \"24h\"\n"
else
  GLUETUN_YAML="gluetun_env:\n  VPN_SERVICE_PROVIDER: \"{{ vault_vpn_provider }}\"\n  OPENVPN_USER: \"{{ vault_vpn_user }}\"\n  OPENVPN_PASSWORD: \"{{ vault_vpn_password }}\"\n  UPDATER_PERIOD: \"24h\"\n"
fi

backup_file "$ALL_FILE"
{
cat <<EOF
---
timezone: "$FACT_TZ"
puid: "$FACT_PUID"
pgid: "$FACT_PGID"
appdata_dir: "/opt/appdata"
storage_merged: "/mnt/storage"

# Local subnet so Gluetun allows access to the WebUIs from your LAN.
lan_subnet: "$LAN_SUBNET"

# --- Services ---
# Optional services: iptv -> Dispatcharr, management -> Portainer, logs -> Dozzle
compose_profiles: $PROFILES_YAML

# --- VPN (Gluetun) ---
# Every key in this dict is passed to the Gluetun container as an environment
# variable — any provider/protocol from https://github.com/qdm12/gluetun-wiki works.
EOF
printf '%b' "$GLUETUN_YAML"
cat <<EOF

# --- Storage ---
# One entry per data disk. 'fstype' is optional and defaults to ext4.
data_disks:
EOF
printf '%b' "$DATA_DISKS_YAML"
cat <<EOF

# --- SnapRAID parity (optional) ---
EOF
printf '%b' "$PARITY_YAML"
cat <<EOF

# --- Backups ---
backup_enabled: $BACKUP_ENABLED

# Any Restic backend works (local path, sftp:, s3:, b2:, ...).
restic_repository: "$RESTIC_REPO"

# Extra environment variables for Restic (cloud credentials, values in the vault).
restic_env: {}

EOF
[[ -n "$BACKUP_USB_YAML" ]] && printf '%b\n' "$BACKUP_USB_YAML"
cat <<EOF
# Pinged after every successful backup — leave empty to disable monitoring.
backup_healthcheck_url: "$HEALTHCHECK_URL"

# --- System watchdog & maintenance ---
# Daily check of disk space, disk health (SMART) and container state.
system_healthcheck_url: "$WATCHDOG_URL"
disk_usage_threshold: 90

# Reboot automatically when an update requires it (after the backup window).
auto_reboot: true
auto_reboot_time: "06:30"

# Secrets pulled from the Ansible Vault
tailscale_key: "{{ vault_tailscale_key }}"
restic_pass: "{{ vault_restic_password }}"
EOF
} > "$ALL_FILE"
info "Wrote $ALL_FILE"

umask 077
printf '%s' "$VAULT_PASS" > "$VAULT_PASS_FILE"
info "Wrote .vault_pass"

backup_file "$VAULT_FILE"
VAULT_TMP="$(mktemp)"
trap 'rm -f "$VAULT_TMP"' EXIT
{
  echo "vault_vpn_provider: \"$VPN_PROVIDER\""
  if [[ "$VPN_TYPE" == "wireguard" ]]; then
    echo "vault_wireguard_private_key: \"$WG_KEY\""
    echo "vault_wireguard_addresses: \"$WG_ADDR\""
  else
    echo "vault_vpn_user: \"$VPN_USER\""
    echo "vault_vpn_password: \"$VPN_PASS\""
  fi
  echo "vault_tailscale_key: \"$TS_KEY\""
  echo "vault_restic_password: \"$RESTIC_PASS\""
} > "$VAULT_TMP"
ansible-vault encrypt --vault-password-file "$VAULT_PASS_FILE" --output "$VAULT_FILE" "$VAULT_TMP" >/dev/null
rm -f "$VAULT_TMP"
info "Wrote encrypted $VAULT_FILE"

# --- done ---------------------------------------------------------------------

bold "Configuration complete!"
if [[ -n "$GENERATED_SECRETS" ]]; then
  warn "Store these generated secrets in a password manager NOW — without the vault"
  warn "password and the Restic password, your backups cannot be recovered:"
  printf '%b' "$GENERATED_SECRETS"
  echo
fi

if ask_yn "Deploy to the server now?" "y"; then
  cd "$REPO_DIR/ansible"
  exec ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file "$VAULT_PASS_FILE"
else
  echo "Deploy later with:"
  echo "  cd ansible && ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file ../.vault_pass"
fi
