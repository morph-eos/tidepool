# �� Script di Configurazione NAS

Questa cartella contiene tutti gli script per la configurazione e gestione del sistema NAS.

## 📁 **Struttura del Sistema NAS:**

- **NAS:** `/mnt/nas` (prima partizione 13TB) - Storage principale  
- **Time Machine:** `/mnt/timemachine` (seconda partizione 3TB) - Backup macOS
- **NAS2:** `/mnt/nas2` (1TB) - Storage secondario

## 🛠️ **Script Disponibili:**

### Script di Configurazione:
- **`setup_complete.sh`** - Configurazione completa automatica
- **`setup_disk.sh`** - Configurazione intelligente dei dischi
- **`setup_samba.sh`** - Configurazione servizio Samba
- **`setup_fail2ban.sh`** - SSH hardening + fail2ban (ban dopo 3 tentativi)

### Script di Gestione:
- **`nas-help.sh`** - Guida rapida ai comandi
- **`nas_status.sh`** - Stato completo del sistema
- **`nas_info.sh`** - Informazioni dettagliate e guida utente
- **`change_password.sh`** - Cambio password Samba sicuro
- **`fix_nas.sh`** - Riparazione problemi di mount

### Backup Offsite (Borg + Proton Drive):
- **`backup_offsite.sh`** - Backup giornaliero automatico (cron 03:00)
- **`backup_setup.sh`** - Setup completo del sistema di backup offsite
- **`backup_restore.sh`** - Ripristino file da backup (locale o da Proton Drive)
- **`proton_refresh_session.sh`** - Refresh automatico sessione Proton Drive (2FA)
- **`borg_backup_nas2.sh`** - Backup Borg locale del NAS2

### VM Manager (Incus):
- **`setup_incus.sh`** - Installazione/configurazione Incus + UI web + socat SSH proxy
- **`incus_vm_hook.sh`** - Hook automatico: assegna porte SSH alle VM via socat + systemd

### Manutenzione:
- **`setup_cron.sh`** - Configurazione cron jobs idempotente (certbot restart, log cleanup, backup)
- **`cleanup_logs.sh`** - Pulizia settimanale log (journal, Docker, apt)

## 🚀 **Come Usare:**

### Prima Configurazione:
```bash
# Configurazione completa automatica
./setup_complete.sh --force

# O configurazione interattiva
./setup_complete.sh
```

### Gestione Quotidiana:
```bash
# Verificare stato sistema
./nas_status.sh

# Vedere informazioni complete
./nas_info.sh

# Cambiare password
./change_password.sh
```

### Risoluzione Problemi:
```bash
# Riparare problemi di mount
./fix_nas.sh

# Riconfigurare solo i dischi
./setup_disk.sh --force

# Riconfigurare solo Samba
./setup_samba.sh
```

## 🔄 **Backup Offsite (Proton Drive):**

Il sistema di backup offsite usa **Borg** (deduplica + compressione + encryption) con upload su **Proton Drive** tramite `proton-drive-bridge` (FTP bridge).

### Cosa viene backuppato:
- **docker/data/**: certbot, icloud-photos, immich, nginx, openclaw, jellyfin, radicale, vaultwarden, syncthing/obsidian
- **docker/**: kickstart, scripts, docker-compose.yml, .env, *.sh, README.md
- **nas2/**: media (ebooks+music), nas-scripts, obsidian-index, obsidian-semantic-search

### Come Funziona:
1. Dump PostgreSQL di Immich
2. `borg create` — backup incrementale con deduplica → `/mnt/nas/backup/offsite/`
3. `borg prune` — retention (7 daily, 4 weekly, 6 monthly)
4. Sync verificato file-by-file → Proton Drive via FTP bridge
   - Hash incrementale con cache mtime+size (ricalcola md5 solo per file modificati)
   - Upload + download-verifica md5 per ogni file
   - Restart bridge ogni 50 upload per prevenire degradazione cache
   - Restart bridge tra tentativi di retry su fallimenti di verifica
   - Fallback `.new-<epoch>` per file con overwrite bloccato (bug bridge)
   - Email notifica per azioni manuali (file bloccati, obsoleti, orfani)
   - Email automatica su crash o errore fatale (con riga e exit code)
   - File `nonce` escluso dall'upload (cambia ad ogni run, non serve per il restore)
   - Guard: file scomparsi dal repo tra scan e upload vengono skippati

### File stuck (`.proton-stuck`):
File il cui overwrite FTP fallisce sistematicamente (bug bridge STOR).
- Vengono salvati con nome alternativo `.new-<epoch>` e verificati md5
- Email automatica con lista file da eliminare manualmente da [drive.proton.me](https://drive.proton.me)
- Dopo cleanup manuale, il prossimo run rileva l'overwrite riuscito e rimuove il file dalla lista

### Manifest (`.proton-manifest`):
Formato a 4 campi: `rel_path md5_hash mtime_epoch size_bytes`
- Se mtime+size non cambiano → riusa hash dalla cache (zero I/O disco)
- Run tipico (~10 file cambiati): fase hash **<1s** invece di ~16 min
- Retrocompatibile: manifest a 2 campi (vecchio formato) → ricalcolo completo automatico

### Proton Drive Bridge (`proton-drive-bridge.service`):
- Servizio systemd: `User=root`, `Group=root`, `Environment=HOME=/root`
- FTP bridge su `127.0.0.1:2121`
- **Bug noti del bridge**:
  - STOR su file esistente **non sovrascrive MAI** (bridge serve il vecchio contenuto)
  - DELE non supportato (sempre 451)
  - RNFR/RNTO: RNFR 350 OK, RNTO 451 (rename non funziona)
  - SITE MD5 advertised ma ritorna 451
  - curl exit 18 su upload (partial transfer, contenuto OK)
  - FTP SIZE riporta valori errati
- **Mitigazioni implementate**: restart preventivo ogni 50 upload + restart tra retry + fallback `.new-*`

### Sessione Proton (`proton_refresh_session.sh`):
- Refresh automatico sessione 2FA/keyring
- Sessione in `/root/.local/share/pdrive-bridge` (deve corrispondere al servizio)
- Validazione: vault ≥ 1000 bytes (rileva stub vuoti)

### Setup:
```bash
./backup_setup.sh    # Guida interattiva per configurare tutto
```

### Backup manuale:
```bash
sudo ./backup_offsite.sh
```

### Stato backup:
```bash
sudo tail -30 /var/log/backup-offsite.log          # Log recente
systemctl status proton-drive-bridge               # Stato bridge
sudo wc -l /mnt/nas/backup/offsite/.proton-manifest # File sincronizzati
```

### Ripristino:
```bash
./backup_restore.sh help             # Guida completa
./backup_restore.sh list             # Lista archivi
./backup_restore.sh extract <archivio> /tmp/restore [percorso...]
./backup_restore.sh download         # Scarica repo da Proton Drive
./backup_restore.sh restore-immich-db  # Ripristina DB Immich
```

### Credenziali (chmod 600):
- **Passphrase Borg**: `~/.borg-offsite-passphrase`
- **Password Proton**: `~/.proton-password`
- **Segreto OTP Proton**: `~/.proton-otp-secret`

> ⚠️ **IMPORTANTE**: La passphrase Borg è necessaria per decriptare qualsiasi backup. Conservala in un password manager!

## 🔗 **Accesso Rete:**

- **NAS:** `\\REDACTED_LAN_IP\NAS`
- **NAS2:** `\\REDACTED_LAN_IP\NAS2`  
- **Time Machine:** `\\REDACTED_LAN_IP\TimeMachine`
- **Incus UI:** `https://incus.REDACTED_DOMAIN`
- **SSH VM:** `vm-ssh <nome>` oppure `ssh -p <porta> ubuntu@127.0.0.1`

## 🖥️ **VM Manager (Incus):**

### Architettura:
- **Incus 6.x** (zabbly repo) con `incus-ui-canonical` per UI web
- **Storage:** directory-based su `/mnt/nas2/incus-vms`
- **Rete:** bridge `incusbr0` → `10.100.0.0/24`, NAT via nftables
- **Proxy unificato:** socat via template systemd `incus-port-proxy@<vm>--<nome>.service`
- **iptables:** `incus-iptables.service` per coesistenza con Docker
- **Cloud-init:** auto-installa SSH + inietta chiave host + crea utente `vm-admin`
- **Hook:** timer ogni 30s gestisce tutti i proxy (SSH auto-assegnato + custom)
- **DNS wildcard:** `*.vm.REDACTED_DOMAIN` → VM accessibili dall'esterno via SSH

### Nginx Stream SNI (TLS Passthrough):
nginx usa `ssl_preread` per instradare il traffico sulla porta 443 in base al SNI:
- `incus.REDACTED_DOMAIN` → **TCP passthrough** verso Incus `:8443` (mTLS intatto per login cert)
- tutti gli altri domini → blocco HTTP interno su porta `8442`

Questo permette al browser di presentare il certificato client direttamente a Incus.

### Certificati SSL:
- Incus usa il **certificato Let's Encrypt** tramite symlink:
  - `/var/lib/incus/server.crt` → `certbot/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem`
  - `/var/lib/incus/server.key` → `certbot/live/REDACTED_HOSTNAME.REDACTED_DDNS/privkey.pem`
- Rinnovo automatico: cron `incus-cert-sync` riavvia Incus dopo il rinnovo certbot
- Backup self-signed: `/var/lib/incus/server.crt.selfsigned`

### Sistema Proxy Unificato:
Tutti i proxy sono chiavi `user.proxy.*` sulla VM, visibili/modificabili nella UI (*Configuration > Advanced*):

```bash
# SSH (auto-assegnato al provisioning, modificabile dall'utente)
#   user.proxy.ssh = 2201:22   ← creato automaticamente dal hook

# Esponi nginx della VM sulla porta 8080 dell'host
incus config set myvm user.proxy.web 8080:80

# Esponi Cockpit sul 3001
incus config set myvm user.proxy.cockpit 3001:9090

# Rimuovi un proxy (ferma anche il servizio socat entro 30s)
incus config unset myvm user.proxy.web

# Cambia la porta SSH (il hook aggiorna entro 30s)
incus config set myvm user.proxy.ssh 2205:22
```

- **SSH:** auto-assegnato dal range 2201-2299 (skip 2222), modificabile
- **Custom:** qualsiasi porta ≥ 1000, non in conflitto con Docker/sistema
- **Porte bannate:** < 1000, 22, 80, 443, 2222, porte Docker → chiave rimossa automaticamente
- **Aggiornamento live:** modifica il valore nella UI/CLI → il hook rileva e aggiorna entro 30s

### Auto-discovery porte VM (range 3000-3099):
Il hook scansiona ogni 30s le porte TCP in listen dentro ogni VM RUNNING (`ss -tlnH`,
quindi vede anche docker-proxy e podman rootless-port) ed espone automaticamente quelle
non già mappate. Le chiavi create hanno prefisso `user.proxy.auto-<vmport>`:

- Se `vm_port` è già nel range **3000-3099** ed è libera sull'host → mappa **stessa porta** (es. `3050:3050`)
- Altrimenti → assegna la prima porta libera del range (es. VM:8081 → host:3000)
- Quando il listener nella VM scompare, la chiave `auto-*` viene rimossa entro 30s
- Esclusi: porta 22 (gestita da `user.proxy.ssh`), bind solo loopback (127.0.0.1, ::1)
- Porte 3000-3099 sono già aperte su modem/router → servizi accessibili da fuori

```bash
# Vedi tutti i proxy auto-discovered di una VM
incus config show myvm | grep user.proxy.auto-
```

### MOTD informativo + comando `vm-proxies` dentro la VM:
Al login SSH (con tty) ogni utente vede automaticamente:
- **Header VM**: nome, OS (PRETTY_NAME), kernel, hostname, IP interno, uptime, load, memoria, disco, sessioni attive
- **Logica proxy**: spiegazione completa dei range (2201-2299 SSH, 3000-3099 auto, raggiungibili come `vm.REDACTED_HOSTNAME.REDACTED_DDNS:<porta>`)
- **Tabella proxy attivi** (SSH + auto-discovery + manuali)
- **Lista raggiungibilità da Internet** (solo proxy in 3000-3099)
- **Comandi di gestione** (`incus config set/unset` da host)

Il MOTD è in **inglese**, scritto in `/etc/motd` dal hook ogni 30s (solo se cambia md5).
Lo stesso contenuto è disponibile come comando `vm-proxies` rieseguibile in qualsiasi
momento dall'utente per vedere lo stato corrente:
```bash
vm-proxies   # ovunque, dentro la VM, da qualunque utente
```
Funziona su Rocky/RHEL/Debian/Ubuntu (testato E2E su tutte e tre).

### Comandi rapidi:
```bash
# Setup completo
sudo bash setup_incus.sh install

# Creare una VM
incus launch images:ubuntu/24.04/cloud myvm --vm

# SSH nella VM (dopo ~60s per cloud-init)
vm-ssh myvm

# Stato
sudo bash setup_incus.sh status
```

### File di stato:
- **Port map SSH:** `/mnt/nas2/incus-vms/port-map.txt` (ricostruito dal hook)
- **Env proxy:** `/mnt/nas2/incus-vms/port-proxy/<vm>--<nome>.env`
- **Stato proxy attivi:** `/mnt/nas2/incus-vms/port-proxy-state.txt`
- **UI token:** `~/.incus-ui-token`

## ⏰ **Cron Jobs:**

Gestiti da `setup_cron.sh` con tag `[managed:nas-scripts]` per idempotenza.

| Job | Schedule | Utente |
|-----|----------|--------|
| Backup offsite | `0 3 * * *` | REDACTED_HOSTNAME |
| Certbot restart | `0 5 */7 * *` | REDACTED_HOSTNAME |
| Incus cert reload | `30 5 */7 * *` | root |
| Log cleanup | `0 4 */7 * *` | root |

```bash
sudo bash setup_cron.sh install   # installa/aggiorna
sudo bash setup_cron.sh status    # mostra stato
sudo bash setup_cron.sh remove    # rimuove job gestiti
```

## 👤 **Credenziali Predefinite:**

- **Utente:** `REDACTED_HOSTNAME`
- **Password:** `REDACTED_DEFAULT_PASSWORD`
- **⚠️ IMPORTANTE:** Cambia la password con `./change_password.sh`

## 🔧 **Comandi di Sistema Utili:**

```bash
# Riavviare Samba
sudo systemctl restart smbd

# Vedere log Samba
sudo journalctl -u smbd -f

# Verificare configurazione
sudo testparm -s

# Vedere connessioni attive
sudo smbstatus
```

## 📞 **Supporto:**

- File configurazione Samba: `/etc/samba/smb.conf`
- Mount automatici: `/etc/fstab`
- Log sistema: `sudo journalctl -u smbd`

---
*Sistema configurato il 10 agosto 2025 — Backup offsite aggiunto il 12 aprile 2026 — Hash incrementale (mtime+size) aggiunto il 19 aprile 2026 — Gestione file stuck + email notifiche + esclusione nonce aggiunto il 20 aprile 2026*
