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
4. Sync incrementale file-by-file → Proton Drive via FTP bridge

### Setup:
```bash
./backup_setup.sh    # Guida interattiva per configurare tutto
```

### Backup manuale:
```bash
sudo ./backup_offsite.sh
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
*Sistema configurato il 10 agosto 2025 — Backup offsite aggiunto il 12 aprile 2026*
