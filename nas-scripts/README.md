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
*Sistema configurato il 10 agosto 2025*
