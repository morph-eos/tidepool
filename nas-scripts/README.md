# �� Script di Configurazione NAS

Questa cartella contiene tutti gli script per la configurazione e gestione del sistema NAS.

## 📁 **Struttura del Sistema NAS:**

- **NAS:** `/mnt/nas` (prima partizione 13TB) — Storage principale
  - `media/` — film/serie/musica/foto (montato da Jellyfin come `/media2`, RW)
  - `REDACTED_DIR_1/`, `Sites/`, `REDACTED_DIR_2/`, `REDACTED_DIR_3/`, `TempDownload/`, `Windows Apps/` — dati utente (accessibili via Samba `\\NAS\NAS`)
  - `backup/` — **solo repository gestiti da servizi**: `REDACTED_DRIVE2/`, `REDACTED_DRIVE/`, `offsite/` (Borg). NON aggiungere file qui a mano.
- **Time Machine:** `/mnt/timemachine` (3TB, HFS+ ro) — Backup macOS (write solo da macOS)
- **NAS2:** `/mnt/nas2` (1TB) — Storage secondario
  - `media/` — `ebooks`, `music` (montato da Jellyfin come `/media`, RW)

### Permessi Samba (REDACTED_HOSTNAME:REDACTED_HOSTNAME)
Le radici `/mnt/nas` e `/mnt/nas2` sono `REDACTED_HOSTNAME:REDACTED_HOSTNAME 755` — l'utente Samba `REDACTED_HOSTNAME` può creare/modificare cartelle al top-level. I sottoalberi gestiti da servizi (Docker, Incus, Borg) mantengono ownership originali e non sono toccati da fix permessi.

## 🛠️ **Script Disponibili:**

### Script di Configurazione:
- **`setup_reconfigure.sh`** - Riconfigurazione comoda: servizi host, cron, Samba, mail, OIDC Nextcloud
- **`setup_disk.sh`** - Configurazione intelligente dei dischi
- **`setup_samba.sh`** - Configurazione servizio Samba
- **`setup_nextcloud_oidc.sh`** - Redirect URI client OIDC Nextcloud (Immich/Jellyfin/Vaultwarden)
- **`setup_nginx_realip.sh`** - PROXY protocol sull'hop interno stream→8442 + `real_ip` + `trusted_proxies`/`forwarded_for_headers` Nextcloud, cosi' tutti i vhost vedono l'IP client reale invece di 127.0.0.1 (vedi sezione "Nginx Stream SNI")
- **`setup_nginx_tls_ecdsa.sh`** - Aggiunge le suite `ECDHE-ECDSA-*` alle liste `ssl_ciphers` prive di alternative ECDSA, cosi' TLS1.2 torna negoziabile col certificato ECDSA condiviso (vedi sezione "Certificati SSL")
- **`setup_mail.sh`** - SMTP condiviso: `.env`, Nextcloud, Vaultwarden, SMART/backup
- **`update_immich_version.sh`** - Aggiornamento idempotente tag Immich + pull/recreate container
- **`setup_fail2ban.sh`** - SSH hardening + fail2ban (ban dopo 3 tentativi)
- **`setup_claude_desktop.sh`** - Claude Desktop (autostart + MCP filesystem/Playwright) **e ambiente browser**: installa+inverginazione Chrome (browser di Claude) con policy anti-tracking, Firefox predefinito + privacy (ETP strict). Login manuali a fine setup (Claude Desktop + estensione Claude in Chrome)
- **`setup_REDACTED_NAME_site.sh`** - Riorganizza `REDACTED_NAME.REDACTED_DOMAIN` in `/` (landing, password), `/quotes` (vecchio sito, password invariata), `/festa-ruolo` (Invito REDACTED_NAME, libero — unica location con `auth_basic off`)

### Script di Gestione:
- **`nas-help.sh`** - Guida rapida ai comandi
- **`nas_status.sh`** - Stato completo del sistema
- **`nas_info.sh`** - Informazioni dettagliate e guida utente
- **`change_password.sh`** - Cambio password Samba sicuro
- **`fix_nas.sh`** - Riparazione problemi di mount

### Backup Offsite (Borg + Proton Drive):
> ✅ **Mirror su Proton Drive via CLI ufficiale** (`proton-drive` + `proton_cli_backup.sh`), automatizzato con **systemd user timer** `proton-cli-backup.timer` (03:30). `rclone` non usabile (CAPTCHA/anti-abuso Proton).
- **`backup_offsite.sh`** - Backup giornaliero automatico (cron 03:00). Dump DB (immich pg, nextcloud mariadb, sqlite lock-safe), Borg create, sync Proton Drive con auto-delete (obsoleti/orfani, inclusi metadata root Borg)
- **`backup_setup.sh`** - Setup completo del sistema di backup offsite
- **`backup_restore.sh`** - Ripristino file da backup (locale o da Proton Drive)
- **`borg_backup_nas2.sh`** - Backup Borg locale del NAS2 (cron 04:00, staccato da backup_offsite.sh)
- **`setup_proton_cli_backup.sh`** - Installa il CLI ufficiale Proton + systemd user timer (mirror 03:30). Eseguire come `REDACTED_HOSTNAME`
- **`proton_cli_backup.sh`** - Mirror del repo Borg offsite su Proton Drive (CLI ufficiale, self-healing). Eseguire come `REDACTED_HOSTNAME`

### VM Manager (Incus):
- **`setup_incus.sh`** - Installazione/configurazione Incus + UI web + socat SSH proxy
- **`incus_vm_hook.sh`** - Hook automatico: assegna porte SSH alle VM via socat + systemd

### Manutenzione:
- **`setup_cron.sh`** - Configurazione cron jobs idempotente (certbot restart, log cleanup, backup)
- **`setup_host_services.sh`** - Installa idempotente i servizi systemd custom dell'host (wifi-watchdog + nas-scripts-fixperms)
- **`cleanup_logs.sh`** - Pulizia settimanale log (journal, Docker, apt)
- **`wifi_watchdog.sh`** - Watchdog WiFi: riconnette `REDACTED_WIFI_IFACE` se cade (es. modem riavviato di notte)
- **`incus_vm_hook.sh`** - Hook proxy Incus + DNS sync (eseguito ogni 30s da `incus-dns-sync.timer`)
- **`setup_kdump.sh`** - Abilita kdump (crash kernel dump) per diagnosi panic / hard hang

## 🚀 **Come Usare:**

### Prima Configurazione:
```bash
# Riconfigurazione idempotente dei servizi principali
sudo ./setup_reconfigure.sh install

# Stato sintetico delle configurazioni principali
sudo ./setup_reconfigure.sh status
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

Il sistema usa **Borg** (deduplica + compressione + encryption). Il repo
`/mnt/nas/backup/offsite/` viene mirrorato su **Proton Drive** tramite il **CLI
UFFICIALE** (`proton-drive`). Cron **staggerati** (job separati, non più incatenati
con `;`) per non sovrapporre I/O pesante sullo stesso disco `/mnt/nas`:
- **03:00** `backup_offsite.sh` — dump DB + Borg create verso `/mnt/nas/backup/offsite/`
- **03:30** (+0-5min) mirror Proton Drive via systemd user timer (legge `offsite/`)
- **04:00** `borg_backup_nas2.sh` — scansione `/mnt/nas2` → `/mnt/nas/backup/REDACTED_DRIVE/` (HDD→HDD)

> ⚠️ Prima del 2026-07-05 `borg_backup_nas2.sh` girava incatenato subito dopo
> `backup_offsite.sh` alle 03:00: la scansione pesante di `/mnt/nas2` poteva
> sovrapporsi al mirror Proton (03:30) sullo stesso disco `/mnt/nas`, contesa I/O
> sospettata concausa del soft lockup ext4 del 2026-07-04 (vedi CLAUDE.md pitfall).
> Ora è un cron job separato (`backup-nas2-REDACTED_DRIVE`) alle 04:00.

### Cosa viene backuppato:
- **docker/data/**: certbot, icloud-photos, immich, nginx, jellyfin, nextcloud, nextcloud-db-dumps, sqlite-snapshots, vaultwarden, syncthing/obsidian
- **docker/**: kickstart, scripts, docker-compose.yml, .env, *.sh, README.md
- **nas2/**: media (ebooks+music), nas-scripts, incus-config-backup

### Flusso:
1. Dump DB: Immich PostgreSQL, Nextcloud MariaDB, SQLite lock-safe (vaultwarden/jellyfin)
2. `borg create` incrementale → `/mnt/nas/backup/offsite/`
3. `borg prune` (7 daily, 4 weekly, 6 monthly) + `borg compact`
4. `chown` repo → `REDACTED_HOSTNAME` (borg gira come root; il mirror CLI gira come REDACTED_HOSTNAME)
5. Mirror su Proton (timer `proton-cli-backup.timer`, 03:30) — vedi sotto

### Mirror Proton — `proton_cli_backup.sh` (CLI ufficiale)
- Gira come **REDACTED_HOSTNAME** (sessione/keyring per-utente) via **systemd USER timer**
  (eredita D-Bus + keyring dall'autologin GNOME). Login una-tantum: `proton-drive auth login`.
- Strategia **Borg-aware / self-healing**:
  - metadati (`config`,`nonce`,`README`,`hints.*`,`index.*`,`integrity.*`) → upload **replace**
  - segmenti `data/` (immutabili) → upload **skip** (solo nuovi)
  - **orfani** (vecchie gen metadati, segmenti da compaction) → **trash** sul remoto (reversibile)
- Destinazione: `/my-files/backup/tidepool`. Conservativo (no retry aggressivi → anti-abuso).
- `rclone` NON usabile (CAPTCHA/anti-abuso Proton).
- **Alert email su errore**: se l'upload/riconciliazione fallisce (contatore `FAILED>0`),
  invia un'email di alert via SMTP (stessa logica `.env`/`SMART_*` di `backup_offsite.sh`).
  L'auth-locked (keyring) resta uno **skip silenzioso** (recuperabile, niente rumore).

### Setup / stato / manuale:
```bash
sudo -u REDACTED_HOSTNAME /mnt/nas2/nas-scripts/setup_proton_cli_backup.sh   # install CLI + timer
proton-drive auth login                                              # login una-tantum (GUI)
sudo tail -30 /var/log/proton-cli-backup.log                         # log mirror
sudo -u REDACTED_HOSTNAME /mnt/nas2/nas-scripts/proton_cli_backup.sh         # mirror manuale
sudo ./backup_offsite.sh                                             # backup completo manuale
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

## Email / SMTP condiviso

`setup_mail.sh` normalizza l'invio email dei servizi verso:
- login SMTP: `REDACTED_OWNER_EMAIL`
- mittente visibile: `REDACTED_BRAND' Services <REDACTED_SERVICE_EMAIL>`
- server: `smtp.gmail.com:587` con STARTTLS

La sorgente stabile e' `/mnt/nas2/docker/.env`. Il compose passa le variabili ai container; Nextcloud usa anche l'hook Docker `docker/scripts/nextcloud-smtp-hook.sh` per applicarle a `config.php` a ogni avvio.

> ⚠️ **Fix heredoc email (giu 2026)**: in `backup_offsite.sh` e `proton_cli_backup.sh`
> il default con apostrofo `${smtp_from_name:-REDACTED_BRAND' Services}` **dentro l'heredoc**
> rompeva il parsing bash ("bad substitution") → le email di alert NON partivano mai.
> Ora il from-name e' precalcolato in una variabile `from_name` fuori dall'heredoc.
> Gli alert backup (ERRORE/CRASH offsite + errori mirror Proton) ora funzionano.

```bash
sudo bash /mnt/nas2/nas-scripts/setup_mail.sh install
sudo bash /mnt/nas2/nas-scripts/setup_mail.sh status
```

## � SSO / OIDC (Nextcloud come IdP)

Nextcloud (`https://cloud.REDACTED_DOMAIN`) funge da Identity Provider OIDC. Client registrati:

| Servizio | client_id | Redirect URI |
|----------|-----------|--------------|
| Immich | `REDACTED_CLIENT_ID` | `immich.REDACTED_DOMAIN/auth/login`, `/user-settings`, `app.immich:///oauth-callback` |
| Jellyfin | `REDACTED_CLIENT_ID` | `jellyfin.REDACTED_DOMAIN/sso/OID/redirect/nextcloud` |
| Vaultwarden | `REDACTED_CLIENT_ID` | `bitwarden.REDACTED_DOMAIN/identity/connect/oidc-signin` |

- Utente unificato: `REDACTED_SERVICE_EMAIL` (aggiornato su tutti i servizi)
- Vaultwarden SSO: config in `config.json` (gestito dal pannello admin); `extra_hosts: cloud.REDACTED_DOMAIN:host-gateway` per hairpin NAT
- Nota: SSO su Vaultwarden sostituisce solo l'autenticazione, NON la decryption (master password sempre richiesta)
- Script redirect URI: `setup_nextcloud_oidc.sh install` (idempotente, riconcilia tutti i redirect URI)

```bash
sudo bash /mnt/nas2/nas-scripts/setup_nextcloud_oidc.sh install
sudo bash /mnt/nas2/nas-scripts/setup_nextcloud_oidc.sh status
```

## �🔗 **Accesso Rete:**

- **NAS:** `\\REDACTED_LAN_IP\NAS`
- **NAS2:** `\\REDACTED_LAN_IP\NAS2`  
- **Time Machine:** `\\REDACTED_LAN_IP\TimeMachine`
- **Incus UI:** `https://incus.REDACTED_DOMAIN`
- **SSH VM:** `vm-ssh <nome>` oppure `ssh -p <porta> ubuntu@127.0.0.1`

## 🖥️ **VM Manager (Incus):**

### Architettura:
- **Incus 6.x** (zabbly repo) con `incus-ui-canonical` per UI web
- **Storage:** pool `vmquota` (LVM thin, loop-backed 200GiB). Il backing file e' su
  **`/mnt/nas/incus/vmquota.img`** (disco dati 16TB), con symlink da
  `/var/lib/incus/disks/vmquota.img` (path che Incus ha in `source:`). Vedi `relocate-pool`.
- **Rete:** bridge `incusbr0` → `10.100.0.0/24`, NAT via nftables
- **Proxy unificato:** socat via template systemd `incus-port-proxy@<vm>--<nome>.service`
- **iptables:** `incus-iptables.service` per coesistenza con Docker
- **Cloud-init:** auto-installa SSH + inietta chiave host + crea utente `vm-admin`

### Policy SSH (default per ogni nuova VM):
- **Password auth: ABILITATA** (`PasswordAuthentication yes`, `KbdInteractiveAuthentication yes`)
- **Root login: NEGATO** (`PermitRootLogin no`)
- **MaxAuthTries:** `3`
- **Nessun utente ha password di default:** `vm-admin` e gli altri utenti creati da cloud-init nascono con password locked. L'amministratore della VM sceglie a chi assegnarne una.
- File policy: `/etc/ssh/sshd_config.d/01-REDACTED_BRAND_lc-defaults.conf` (prefisso `01-` per vincere su `50-cloud-init.conf` di Rocky/RHEL — sshd legge la dir in ordine alfabetico e per ogni direttiva vince la prima occorrenza).
- Per assegnare una password a un utente esistente:
  ```bash
  incus exec <vm> -- passwd <user>
  ```
- Per riapplicare la policy a tutte le VM RUNNING (idempotente):
  ```bash
  sudo bash setup_incus.sh fix-vm-ssh
  ```
- **Hook:** timer ogni 30s gestisce tutti i proxy (SSH auto-assegnato + custom)
- **DNS wildcard:** `*.vm.REDACTED_DOMAIN` → VM accessibili dall'esterno via SSH

### Nginx Stream SNI (TLS Passthrough):
nginx usa `ssl_preread` per instradare il traffico sulla porta 443 in base al SNI:
- `incus.REDACTED_DOMAIN` → **TCP passthrough** verso un relay interno `127.0.0.1:18443` che rimuove il PROXY protocol, poi verso Incus `:8443` (mTLS intatto per login cert)
- tutti gli altri domini → blocco HTTP interno su porta `8442`

Questo permette al browser di presentare il certificato client direttamente a Incus.

**IP client reale (`setup_nginx_realip.sh`):** l'hop `stream→127.0.0.1:8442` e' una NUOVA
connessione TCP che nginx apre verso se stesso: senza accorgimenti, ogni vhost su `8442`
vedrebbe sempre `$remote_addr=127.0.0.1` (bruteforce-protection/log per-IP condivisi da
tutti i client, es. Nextcloud). Fix: PROXY protocol abilitato sul quel hop
(`proxy_protocol on;` lato stream, `listen 8442 ... proxy_protocol;` + `real_ip_header
proxy_protocol;` + `set_real_ip_from 127.0.0.1;` lato http). Incus non supporta PROXY
protocol: il branch `incus.REDACTED_DOMAIN` passa quindi per il relay dedicato
`127.0.0.1:18443` (accetta+rimuove l'header) prima di raggiungere Incus, cosi' l'mTLS
resta bit-per-bit intatto. Nextcloud e' inoltre configurato con `trusted_proxies=172.18.0.0/16`
(subnet `docker_default`, non l'IP specifico di nginx che cambia se il container viene
ricreato) e `forwarded_for_headers=HTTP_X_FORWARDED_FOR`.

### Certificati SSL:
- Il certificato Let's Encrypt condiviso e' **ECDSA (prime256v1)**, non RSA. Le liste
  `ssl_ciphers` su quasi tutti i vhost (main site, Immich, Jellyfin, Plex, Vaultwarden,
  WebDAV, Syncthing, Nextcloud, REDACTED_NAME) contenevano solo suite `ECDHE-RSA-*`/`DHE-RSA-*`
  (nessuna valida per un certificato ECDSA): TLS1.2 era quindi "abilitato" ma senza
  nessun cifrario realmente negoziabile, mentre TLS1.3 funzionava (li' la firma si
  negozia separatamente). Qualunque client TLS1.2-only (Android <10, ExoPlayer/player
  che usano lo stack TLS di sistema) falliva l'handshake su ogni servizio. Fix:
  `setup_nginx_tls_ecdsa.sh` (idempotente) aggiunge `ECDHE-ECDSA-AES128-GCM-SHA256` e
  affini davanti alle liste esistenti. Il vhost `modem`, che non sovrascriveva
  `ssl_ciphers` con quella lista, non erano mai stati affetti (da qui la controprova).
- Incus usa lo stesso **certificato Let's Encrypt unico** di nginx/certbot tramite symlink:
  - `/var/lib/incus/server.crt` → `certbot/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem`
  - `/var/lib/incus/server.key` → `certbot/live/REDACTED_HOSTNAME.REDACTED_DDNS/privkey.pem`
- Il certificato unico deve includere anche `incus.REDACTED_DOMAIN` nei SAN; il dominio e' dichiarato nel `certbot` del compose principale e nel compose di kickstart.
- nginx mantiene un server HTTP `:80` solo per `/.well-known/acme-challenge/` e redirect HTTPS; serve a certbot anche quando la porta 443 e' gestita dallo stream SNI.
- Rinnovo automatico: cron `incus-cert-sync` riavvia Incus dopo il rinnovo certbot
- Backup self-signed: `/var/lib/incus/server.crt.selfsigned`
- Certificati client trusted gestiti da `setup_incus.sh trust-certs`: mettere i `.crt` pubblici in `/mnt/nas2/nas-scripts/incus-trust/` con nome stabile. Il file `incus-ui-notebook.crt` viene registrato in Incus come `incus-ui-notebook`.

### Storage e quote:
- Il pool `vmquota` usa driver **LVM thin** (loop-backed, 200GiB). Non ripartiziona e non formatta i dischi NAS.
- **Backing file su disco dati (16TB)**: il file e' `/mnt/nas/incus/vmquota.img`, con symlink
  da `/var/lib/incus/disks/vmquota.img` (il path che Incus tiene in `source:`). Cosi' la
  crescita thin **non riempie il disco di sistema `/`** (rischio I/O error → corruzione dqlite).
- **`setup_incus.sh relocate-pool`** (idempotente): sposta il backing file dal default
  (`/var/lib/incus/disks/`, su `/`) a `/mnt/nas/incus/` e lascia il symlink. Ferma le VM e il
  daemon, copia **sparse** (preserva i buchi: non gonfia a 200G), riavvia tutto. Se il source
  e' gia' un symlink al target → **no-op**. Non tocca il DB dqlite (solo filesystem + symlink).
  Il backup dell'originale (`*.pre-relocate.bak`) va rimosso a mano dopo aver verificato le VM.
- Creato e gestito da `setup_incus.sh migrate-storage` / `migrate-quota-storage` (idempotente). Se tutto e' gia' su `vmquota`, il comando e' no-op e pulisce solo eventuali pool legacy vuoti.
- Quote garantite: i volumi **block** e **filesystem** sono thin volume LVM con dimensione rigida; la UI Incus non mostra il warning btrfs sulle quote.
- Per ridimensionare il pool: `incus storage set vmquota size=<new>`.
- Le VM usano volumi block (`virtual-machine/<nome>`); il profilo default imposta `root.size: 20GB`.
- I volumi custom possono essere **block** o **filesystem**. Per i block la VM li vede come `/dev/sdX` con la dimensione esatta.
  - Vanno formattati e montati dentro la VM (`mkfs.ext4 /dev/sdb && mount ...`).
  - `setup_incus.sh migrate-volumes-block` converte eventuali volumi filesystem residui a block (idempotente).
  - Il content-type di default per nuovi volumi custom e' `filesystem`. Per creare volumi block usare sempre `--type block`:
    ```
    incus storage volume create vmquota nome-disco --type block size=10GiB
    ```
    Dalla UI: creare il volume come "block" (non "filesystem") oppure aggiungere un disco custom dalla config VM specificando il tipo.
- I vecchi pool `default` (dir) e `vmpool` (btrfs) sono rimossi quando vuoti dalla migrazione idempotente.

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
Al login SSH ogni utente vede un **MOTD sintetico** con:
- nome VM + hostname + OS + uptime
- host pubblico (`vm.REDACTED_HOSTNAME.REDACTED_DDNS`) e range porte aperte da Internet
- invito a lanciare `vm-proxies` (status) o `vm-proxies --help` (spiegone completo)

Il comando `/usr/local/bin/vm-proxies` è disponibile a qualsiasi utente:

```bash
vm-proxies          # default: VM info live + tabella proxy attivi (con * sui pubblici)
vm-proxies --help   # spiegazione completa: range, lifecycle, comandi di gestione
vm-proxies --motd   # banner sintetico (lo stesso che vedi al login)
```

Sia il MOTD sia il comando sono rigenerati dal hook ogni 30s (push via `incus file
push` solo se md5 cambia). Funziona su Rocky/RHEL/Debian/Ubuntu (testato E2E).

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

## 📡 **WiFi Watchdog (`wifi-watchdog.timer`):**

Il PC e' connesso via WiFi (`REDACTED_WIFI_IFACE` su SSID `REDACTED_WIFI_SSID`). Quando il modem si riavvia di notte, NetworkManager a volte va in stato `failed (no-secrets)` durante il 4-way handshake e **non riprova piu'** anche con `autoconnect-retries=0`, lasciando l'host irraggiungibile fino al reset manuale (successo gia' avvenuto: 30 apr 2026, downtime 02:46 → 10:02).

Mitigazione: `wifi_watchdog.sh` lanciato ogni 60s da systemd timer.
- Se Ethernet (`REDACTED_ETH_IFACE`) ha gia' un IP → exit (no-op, cavo wins)
- Se device WiFi assente → `rfkill unblock wifi`
- Se non connesso o gateway `192.0.2.1` non risponde → `nmcli device disconnect` + `wifi rescan` + `connection up`

```bash
systemctl status wifi-watchdog.timer
journalctl -u wifi-watchdog.service -n 50      # ultimi run
journalctl -t wifi-watchdog -n 50              # solo log dello script
sudo /mnt/nas2/nas-scripts/wifi_watchdog.sh    # esecuzione manuale
```

> 💡 **Soluzione migliore:** collegare il PC via cavo Ethernet (lo script si auto-disabilita appena vede `REDACTED_ETH_IFACE` con IP).

```bash
sudo bash setup_cron.sh install   # installa/aggiorna
sudo bash setup_cron.sh status    # mostra stato
sudo bash setup_cron.sh remove    # rimuove job gestiti
```

## 👤 **Credenziali Predefinite:**

- **Utente:** `REDACTED_HOSTNAME`
- **Password:** `REDACTED_DEFAULT_PASSWORD`
- **⚠️ IMPORTANTE:** Cambia la password con `./change_password.sh`
## 🧩 **Mappa servizi systemd custom (chi installa cosa):**

Tutti i servizi systemd custom dell'host sono installati idempotente da uno script della suite. **Disaster recovery:** rilancia gli script nell'ordine sotto e ottieni lo stesso stato.

| Unit | Installato da | Note |
|------|---------------|------|
| `incus-dns-sync.{service,timer}` | `setup_incus.sh` | Hook proxy + DNS Incus, ogni 30s |
| `incus-iptables.service` | `setup_incus.sh` | Coesistenza Docker/Incus |
| `incus-port-proxy@.service` | `setup_incus.sh` | Template socat per VM |
| `wifi-watchdog.{service,timer}` | `setup_host_services.sh` | Riconnessione WiFi ogni 60s |
| `nas-scripts-fixperms.{service,timer}` | `setup_host_services.sh` | `chmod 0775 *.sh` ogni 5 min |
| Cron jobs | `setup_cron.sh` | backup_offsite, certbot, cleanup, ... |
| `linux-crashdump` (kdump) | `setup_kdump.sh` | On-demand, richiede reboot |

Servizi custom NON gestiti da questa suite (manuali / app):
- `docker-ensure-containers.service` (kickstart Docker compose, vedi `docker/`)

```bash
# Riconfigurazione ordinaria idempotente
sudo bash setup_reconfigure.sh install      # host services + cron + Samba + mail + OIDC

# Componenti con prerequisiti dedicati
sudo bash setup_incus.sh install            # Incus stack
sudo bash backup_setup.sh                   # Borg + Proton Drive
# (kdump on-demand)
sudo bash setup_kdump.sh && sudo reboot

# Stato sintetico
sudo bash setup_reconfigure.sh status
sudo bash setup_incus.sh status
```
## �️ **Note operative — script bit eseguibile:**

La partizione `/mnt/nas2` e' `ext4 rw,relatime` (no `noexec`), MA gli script possono perdere il bit `+x` durante operazioni Samba/restore (es. `cp` da macOS, `create mask` Samba che azzera l'exec). Se un servizio systemd va in `status=203/EXEC`, controllare i permessi:

```bash
find /mnt/nas2/nas-scripts -maxdepth 1 -name '*.sh' ! -perm -u+x
sudo chmod 0775 /mnt/nas2/nas-scripts/*.sh
```

**Mitigazione automatica:** `nas-scripts-fixperms.timer` riapplica `chmod 0775 *.sh` ogni 5 minuti.

```bash
systemctl status nas-scripts-fixperms.timer
sudo systemctl start nas-scripts-fixperms.service   # esegui subito
```

Servizi che dipendono da script qui dentro:
- `incus-dns-sync.service` → `incus_vm_hook.sh`
- `wifi-watchdog.service` → `wifi_watchdog.sh`
- `nas-scripts-fixperms.service` → `find ... chmod 0775` (solo binari di sistema)
- cron `backup_offsite.sh` (lanciato con `bash`, non sensibile a `+x`)

## 💥 **Kdump (crash dump del kernel):**

`setup_kdump.sh` configura kdump per catturare crash dump in caso di kernel panic, soft/hard lockup o MCE (Machine Check Exception). Utile su host headless senza console fisica per diagnosi post-mortem.

> ✅ **Applicato il 2026-07-05** dopo un soft lockup ext4 del 2026-07-04 (CPU bloccata
> 16.5h, poi macchina giu' ~13h45min senza dump ne' auto-reboot — vedi CLAUDE.md
> pitfall). Prima di quella data lo script esisteva ma non era mai stato eseguito
> (GRUB aveva solo `quiet splash`, kdump-tools non installato). Riattiva al prossimo
> reboot (reservation crashkernel richiede riavvio).

**Cosa fa:**
- Installa `linux-crashdump`, `kdump-tools`, `crash`, `makedumpfile`
- Aggiunge a GRUB: `crashkernel=256M-:256M` (riserva 256 MB RAM per il crash kernel)
- Aggiunge: `softlockup_panic=1 nmi_watchdog=1 panic=10 sysrq_always_enabled=1`
  - `softlockup_panic=1` → lockup CPU ≥22s diventa panic (con dump)
  - `nmi_watchdog=1` → hard lockup rilevato via NMI
  - `panic=10` → reboot automatico 10s dopo il panic (post-dump)
- Compressione dump: `MAKEDUMP_ARGS="-c -d 31"` (solo pagine interessanti)
- Mantiene ultimi 3 dump in `/var/crash/`

**Quando NON serve:**
- Hard reset elettrico (kernel non gira piu')
- Perdita di rete senza panic (es. caso WiFi down 30 apr 2026)
- Crash applicativo (per quello c'e' `systemd-coredump`)

**Quando serve:**
- Kernel panic (driver buggato, BUG_ON, NULL deref)
- Soft/hard lockup (CPU bloccata, deadlock)
- Machine Check Exception (RAM ECC, CPU bug)

**Setup (richiede reboot):**
```bash
sudo bash /mnt/nas2/nas-scripts/setup_kdump.sh
sudo reboot
# dopo reboot:
kdump-config show
cat /sys/kernel/kexec_crash_loaded   # deve essere 1
grep crashkernel /proc/cmdline
```

**Test (DISTRUTTIVO, causa panic reale):**
```bash
echo c | sudo tee /proc/sysrq-trigger
# Il sistema panica, kdump scrive vmcore in /var/crash/<timestamp>/, poi riavvia
```

**Analisi dump:**
```bash
cd /var/crash/202604300213/
sudo crash /usr/lib/debug/boot/vmlinux-$(uname -r) vmcore
# In crash: bt (stack trace), log (dmesg), ps, sys
```

**Costo:** ~256 MB RAM riservata al boot; ogni dump compresso ~200-800 MB.

## �🔧 **Comandi di Sistema Utili:**

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
