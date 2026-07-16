# Lean & Mean Homeserver IaC

GitOps-gebaseerde infrastructuur (Infrastructure as Code) voor een geautomatiseerde, super-efficiënte 4K Media Server. Speciaal ontworpen en geoptimaliseerd voor een energiezuinige **Intel N100** homeserver (geschikt voor max 4 gelijktijdige 4K-kijkers).

---

## 🚀 Key Features

* **100% GitOps & IaC:** Het volledige beheer en de configuratie van de server (OS, schijven, netwerk, containers en back-ups) wordt geregeld via Ansible-playbooks. Aanpassingen doe je in Git en rol je centraal uit.
* **Intel QuickSync Hardware Transcoding:** Volledige hardwarematige H.265/HEVC transcodering via de `/dev/dri` GPU-mapping in Jellyfin, waardoor de CPU nauwelijks belast wordt.
* **Storage Pooling via MergerFS:** Bundelt meerdere data-schijven transparant samen in één virtuele pool `/mnt/storage` zonder RAID-overhead.
* **TRASH Guides Compliant Mappenstructuur:** Gedeelde volumemapping `${STORAGE_DIR}/data:/data` met direct daaronder `/torrents` en `/media`. Dit maakt instant **hardlinks (atomic moves)** mogelijk tussen qBittorrent en Radarr/Sonarr, wat schijfslijtage voorkomt en I/O elimineert.
* **VPN Killswitch via Gluetun:** qBittorrent en Dispatcharr sturen al hun verkeer exclusief door de Gluetun VPN-container. Als de VPN-verbinding faalt, blokkeert Gluetun direct al het verkeer.
* **Automatische Restic Backups:** Dagelijkse incrementele, versleutelde back-ups van `/opt/appdata` naar een aangesloten USB-schijf, automatisch ingepland via Ansible-cron.
* **Tailscale Integratie:** Veilige toegang op afstand tot al je services via je eigen private WireGuard VPN-meshnetwerk.

---

## 🛠️ Stack Componenten

* **Media & Automatisering:** Jellyfin, Radarr, Sonarr, Prowlarr, Bazarr, Jellyseerr.
* **Downloaders:** qBittorrent, Dispatcharr (IPTV).
* **Beheer & Monitoring:** Portainer (containerbeheer), Dozzle (live log viewer).
* **Netwerk & Veiligheid:** Gluetun (VPN), Tailscale (Mesh VPN), UFW (Firewall).

---

## 🔄 Versiebeheer van images

Alle containers draaien bewust op de `:latest`-tag en worden bij elke deploy opgehaald (`pull: always`). Dit houdt de stack automatisch up-to-date en maximaal "plug & play". De tradeoff: een uitrol is niet 100% reproduceerbaar en een breaking image-update kan bij de volgende deploy iets omleggen. Wil je meer controle, dan kun je per service een concrete versie-tag pinnen in `compose/docker-compose.yml` en Restic gebruiken om terug te rollen bij problemen.

---

## 📁 Storage & Data Layout

De schijven worden via MergerFS samengevoegd. De mappenstructuur op `/mnt/storage` is als volgt ingericht voor optimale werking van de *arr-apps:

```text
/mnt/storage/
└── data/
    ├── torrents/          # Downloadmap voor qBittorrent
    │   ├── movies/
    │   └── tv/
    └── media/             # Bibliotheek voor Jellyfin (hardlinks)
        ├── movies/
        └── tv/
```

---

## 📖 Installatie & Disaster Recovery

Voor het bootstrappen van een gloednieuwe server of het herstellen van een back-up na een crash, raadpleeg de gedetailleerde handleiding:

👉 **[Installatie & Disaster Recovery Gids (BOOTSTRAP.md)](BOOTSTRAP.md)**

---

## 💡 Optimalisatie-tip: TRASH Guides Custom Formats

Om HEVC/H.265-optimalisatie toe te passen zonder dat je server hoeft te transcoderen (direct afspelen op geschikte clients):
1. Open Radarr en Sonarr.
2. Importeer de TRASH Guides Custom Formats voor `HEVC/x265` en geef deze een score van bijvoorbeeld `+100`.
3. Dit dwingt de download-client om direct compacte, pre-gecomprimeerde video's te downloaden die perfect aansluiten op jouw netwerk en opslag.