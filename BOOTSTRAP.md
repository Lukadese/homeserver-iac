# Installatie & Disaster Recovery Gids

Deze gids beschrijft hoe je de homeserver vanaf nul installeert (Bootstrapping) en hoe je een back-up herstelt in het geval van een crash (Disaster Recovery).

---

## 1. Eerste Installatie (Bootstrap)

Volg deze stappen om het project voor de eerste keer uit te rollen op een nieuwe server:

### Stap 1: OS & Netwerk
1. Installeer een schone versie van **Debian** (of Ubuntu Server) op de Intel N100 server.
2. Zorg ervoor dat SSH-toegang werkt en dat jouw gebruiker `sudo`-rechten heeft.
3. Sluit de harde schijven en de USB-backupschijf fysiek aan op de server.

### Stap 2: Beheermachine voorbereiden (Laptop)
1. Installeer **Git** en **Ansible** op je laptop.
2. Clone deze repository naar je laptop:
   ```bash
   git clone <jouw-repo-url>
   cd homeserver-iac
   ```

### Stap 3: Schijf-UUID's achterhalen
1. Log in op de nieuwe server via SSH.
2. Run het volgende commando om de UUID's van je aangesloten harde schijven en USB-stick te achterhalen:
   ```bash
   sudo blkid
   ```
3. Kopieer de UUID's van de data-schijven (bijv. `/dev/sdb1`, `/dev/sdc1`) en de USB-backupschijf.

### Stap 4: Configuratie bijwerken
1. Open [ansible/inventory/hosts.yml](ansible/inventory/hosts.yml) op je laptop en pas het IP-adres (`ansible_host`) en de gebruikersnaam (`ansible_user`) aan.
2. Open [ansible/inventory/group_vars/all.yml](ansible/inventory/group_vars/all.yml) en vervang de voorbeeld-UUID's bij `data_disks` en `backup_usb` door de echte UUID's van jouw schijven. Pas hier ook `lan_subnet` aan naar het subnet van jouw thuisnetwerk.

### Stap 5: Ansible Vault wachtwoord instellen
1. Zorg ervoor dat je het wachtwoord van de Ansible Vault bij de hand hebt.
2. Maak een bestand genaamd `.vault_pass` aan in de root van dit project (dit bestand is al toegevoegd aan `.gitignore` zodat het nooit naar GitHub wordt gepusht):
   ```bash
   echo "JOUW_VAULT_WACHTWOORD" > .vault_pass
   ```

### Stap 6: Het Playbook uitvoeren (Deploy)
1. Navigeer op je laptop naar de `ansible` map en start de uitrol:
   ```bash
   ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file ../.vault_pass
   ```
2. Ansible regelt nu de rest:
   - Systeem-updates en basispakketten installeren (`mergerfs`, `restic`, `ufw`, `curl`, `git`).
   - Schijven koppelen en MergerFS configureren op `/mnt/storage`.
   - Tailscale installeren en activeren.
   - De back-upscripts configureren en inplannen via cron.
   - Docker installeren en de volledige mediastack opstarten.

---

## 2. Disaster Recovery (Restore)

Als je server is gecrasht en je een nieuwe Debian-installatie hebt klaargezet, volg dan deze stappen om al je Docker-data en configuraties (appdata) te herstellen:

### Stap 1: Basis uitrol
1. Volg **Stap 1 t/m Stap 6** van de eerste installatie hierboven. Dit zorgt ervoor dat alle schijven, MergerFS en Restic correct zijn geïnstalleerd en het restore-script klaarstaat op de server.

### Stap 2: Docker containers stoppen
Voordat je de database- en configuratiebestanden overschrijft, moet de mediastack tijdelijk worden stopgezet. Log in op de server en voer uit:
```bash
docker stop jellyfin radarr sonarr prowlarr bazarr dispatcharr seerr || true
```

### Stap 3: Restore-script uitvoeren
Voer het gegenereerde restore-script uit op de server:
```bash
sudo /opt/scripts/restore.sh
```
*Dit script vraagt om bevestiging, leest de meest recente back-up van je USB-schijf via Restic en zet deze terug naar `/opt/appdata`.*

### Stap 4: Server herstarten of containers starten
Zodra de restore is voltooid, kun je de server herstarten of de mediastack direct opnieuw opstarten:
```bash
cd /opt/appdata
docker compose up -d
```
Jouw media server is nu weer volledig up-to-date en operationeel!