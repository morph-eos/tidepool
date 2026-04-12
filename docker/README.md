# 🌐 REDACTED_HOSTNAME_TC Cloud Platfor- **🌐 Nginx**: Reverse proxy con SSL/TLS
- **📸 Immich**: Gestione foto e video self-hosted
- **☁️ iCloudPD**: Sincronizzazione automatica foto iCloud (opzionale)
- **🎬 Jellyfin**: Media server per streaming video/audio
- **🎭 Plex**: Media server alternativo per streaming
- **🔄 JellyPlex-Watched**: Sincronizzazione stato visualizzazione tra media server
- **🔐 Bitwarden (Vaultwarden)**: Password manager self-hosted
- **🧠 SMART Check**: Monitoraggio salute dischi con alert email
- **🔒 Certbot**: Certificati SSL automatici Let's Encryptttaforma cloud self-hosted con Immich (gestione foto), Jellyfin/Plex (media server), tramite nginx con certificati SSL automatici.

## 🚀 Quick Start

```bash
# 1. Verifica e configura l'ambiente
./check.sh --install   # Installa automaticamente dipendenze mancanti
# OPPURE
./check.sh             # Solo verifica senza installare

# 2. Configura il file .env (creato automaticamente se mancante)
# Modifica .env con i tuoi valori reali

# 3. Deploy automatico
./deploy.sh
```

Il deploy script si occupa automaticamente di:
- ✅ Installare dipendenze mancanti (se richiesto)
- ✅ Verificare la configurazione
- ✅ Creare il file .env template se mancante
- ✅ Ottenere certificati SSL (se necessario)
- ✅ Avviare tutti i servizi

## 📋 Servizi Inclusi

- **🌐 Nginx**: Reverse proxy con SSL/TLS
- **📸 Immich**: Gestione foto e video self-hosted
- **🎬 Jellyfin**: Media server per streaming video/audio
- **� Plex**: Media server alternativo per streaming
- **🔄 JellyPlex-Watched**: Sincronizzazione stato visualizzazione tra media server
- **🔐 Bitwarden (Vaultwarden)**: Password manager self-hosted
- **🧠 SMART Check**: Monitoraggio SMART dischi con alert email
- **🔒 Certbot**: Certificati SSL automatici Let's Encrypt

## 🔧 Gestione

### Deploy e Aggiornamenti

```bash
./check.sh           # Verifica configurazione sistema
./check.sh --install # Verifica e installa dipendenze mancanti
./deploy.sh          # Deploy completo (certificati + servizi)
./utils.sh update     # Aggiorna immagini Docker
./utils.sh restart    # Riavvia tutti i servizi
```

### Monitoraggio
```bash
./utils.sh status     # Stato servizi e risorse
./utils.sh logs       # Log in tempo reale
docker-compose ps     # Stato servizi
```

### Manutenzione
```bash
./utils.sh backup     # Backup database Immich
./utils.sh renew      # Rinnova certificati SSL
./utils.sh clean      # Pulizia Docker
```

### Backup Offsite (Proton Drive)
```bash
# Backup manuale (normalmente automatico via cron alle 03:00)
sudo /mnt/nas2/nas-scripts/backup_offsite.sh

# Stato backup
systemctl status proton-drive-bridge     # Bridge FTP → Proton
BORG_PASSCOMMAND="cat ~/.borg-offsite-passphrase" borg list /mnt/nas/backup/offsite/

# Ripristino
/mnt/nas2/nas-scripts/backup_restore.sh help

# Setup da zero
/mnt/nas2/nas-scripts/backup_setup.sh
```

```
### Gestione iCloud (Opzionale)
```bash
./utils.sh icloud login   # Modalità interattiva per autenticazione 2FA
./utils.sh icloud start   # Avvia sincronizzazione iCloud
./utils.sh icloud status  # Stato sincronizzazione
./utils.sh icloud logs    # Log in tempo reale
./utils.sh icloud stop    # Ferma sincronizzazione
./utils.sh icloud test    # Verifica configurazione
```

### Gestione Emergenze
```bash
./utils.sh stop       # Ferma tutti i servizi
./utils.sh reset      # Reset completo (⚠️ cancella tutto)
```

## 🌍 Accesso Servizi

Dopo il deploy, i servizi sono disponibili su:

- **🌐 Sito principale**: https://REDACTED_HOSTNAME.REDACTED_DDNS
- **📸 Immich**: https://immich.REDACTED_HOSTNAME.REDACTED_DDNS
- **🎬 Jellyfin**: https://jellyfin.REDACTED_HOSTNAME.REDACTED_DDNS
- **� Plex**: https://plex.REDACTED_HOSTNAME.REDACTED_DDNS
- **🔐 Bitwarden**: https://bitwarden.REDACTED_HOSTNAME.REDACTED_DDNS

### Debug Locale
- **Nginx**: http://localhost:80 / https://localhost:443

## ⚙️ Configurazione

### Prerequisiti

Su Ubuntu/Debian, lo script di check può installare automaticamente le dipendenze:

```bash
./check.sh --install
```

Le dipendenze installate automaticamente includono:
- **Docker**: Containerizzazione
- **Docker Compose**: Orchestrazione servizi (versione 1.x compatibile)
- **curl**: Client HTTP per test
- **net-tools**: Strumenti di rete (netstat)
- **dnsutils**: Strumenti DNS (nslookup)

**Nota**: I file docker-compose utilizzano la sintassi `version: '3.8'` per compatibilità con versioni Ubuntu LTS che includono docker-compose più datate.

### File .env Richiesto

Il file .env viene creato automaticamente se mancante:

```bash
# Email per certificati SSL
EMAIL=tua-email@domain.com

# Password sicure (CAMBIA QUESTE!)
IMMICH_DB_PASSWORD=password-sicura-immich

# Altri parametri sono già configurati
```

**⚠️ IMPORTANTE**: Modifica sempre le password predefinite prima del deploy!

### Configurazione iCloud (Opzionale)

Per sincronizzare automaticamente le foto da iCloud:

1. **Prima autenticazione (richiesta)**:
   ```bash
   # Configura solo l'username nel .env
   ICLOUD_USERNAME=tuo@email.icloud.com
   
   # Avvia modalità interattiva per 2FA
   ./utils.sh icloud login
   ```
   Segui le istruzioni per completare l'autenticazione 2FA.

2. **Avvia sincronizzazione regolare**:
   ```bash
   ./utils.sh icloud start
   ```

3. **Aggiungi a Immich**:
   - Accedi a Immich
   - Vai in "Amministrazione" > "Librerie esterne"
   - Aggiungi `./data/icloud-photos/` come libreria

### Configurazione Jellyfin

Per Jellyfin, devi configurare i percorsi dei tuoi file media nel file `.env`:

```bash
# Modifica questi percorsi per puntare ai tuoi file media reali
JELLYFIN_MEDIA=/path/to/your/movies/and/tv/shows
JELLYFIN_MEDIA2=/path/to/your/music/and/audiobooks

# User ID e Group ID devono corrispondere al proprietario dei file media
JELLYFIN_UID=1000  # Controlla con: id -u
JELLYFIN_GID=1000  # Controlla con: id -g
```

**Nota**: I file media devono essere accessibili dall'utente specificato in JELLYFIN_UID/GID.

### Configurazione Bitwarden (Vaultwarden)

Parametri principali nel `.env`:

```bash
BITWARDEN_DOMAIN=https://bitwarden.REDACTED_HOSTNAME.REDACTED_DDNS
BITWARDEN_ADMIN_TOKEN=<hash argon2>
BITWARDEN_SIGNUPS_ALLOWED=false
BITWARDEN_SIGNUPS_VERIFY=false
```

SMTP per inviti/2FA (usa lo stesso account Gmail o SMTP dedicato):

```bash
BITWARDEN_SMTP_HOST=smtp.gmail.com
BITWARDEN_SMTP_PORT=465
BITWARDEN_SMTP_SSL=true
BITWARDEN_SMTP_EXPLICIT_TLS=false
BITWARDEN_SMTP_FROM=tuo@email.com
BITWARDEN_SMTP_FROM_NAME=Nome mittente
BITWARDEN_SMTP_USERNAME=tuo@email.com
BITWARDEN_SMTP_PASSWORD=app_password
```

Admin panel: `https://bitwarden.REDACTED_HOSTNAME.REDACTED_DDNS/admin`

### Configurazione SMART Check (dischi)

Parametri nel `.env`:

```bash
SMART_DEVICES="/dev/sda /dev/sdb"
SMART_CHECK_INTERVAL=12h
SMART_ALERT_EMAIL=tuo@email.com
SMART_SMTP_HOST=smtp.gmail.com
SMART_SMTP_PORT=465
SMART_SMTP_USERNAME=tuo@email.com
SMART_SMTP_PASSWORD=app_password
SMART_SMTP_FROM=tuo@email.com
SMART_SMTP_FROM_NAME=SMART Monitor
```

Il container invia una mail di avvio ad ogni restart e un alert solo se SMART fallisce.

### Configurazione JellyPlex-Watched (Opzionale)

JellyPlex-Watched sincronizza automaticamente lo stato di visualizzazione tra Jellyfin e altri media server come Plex ed Emby. Per abilitarlo:

```bash
# Configura nel file .env i token di accesso per i tuoi media server
JELLYFIN_TOKEN=your-jellyfin-api-token
JELLYFIN_BASEURL=http://jellyfin:8096
PLEX_TOKEN=your-plex-token
PLEX_BASEURL=http://plex:32400

# Il servizio si avvia automaticamente dopo che Jellyfin e Plex sono healthy
```

**Come ottenere i token**:
- **Jellyfin**: Dashboard → Advanced → API Keys → Aggiungi chiave API
- **Plex**: Vai su https://app.plex.tv/desktop e cerca "X-Plex-Token" negli headers di rete

**Funzionalità**:
- ✅ Sincronizzazione bidirezionale stato "visto/non visto"
- ✅ Sincronizzazione progresso di visualizzazione
- ✅ Mappatura automatica tramite nomi file e ID provider
- ✅ Supporto multi-utente con mappatura nomi utente
- ✅ Health check automatici per garantire connettività
- ✅ Avvio intelligente dopo che i server media sono pronti

**Gestione avanzata**:
```bash
./utils.sh sync status    # Stato sincronizzazione
./utils.sh sync test      # Test connessioni (dal container)
./utils.sh sync logs      # Log in tempo reale
./utils.sh sync restart   # Riavvia servizio
```

### DNS Richiesto

Configura questi record A nel tuo DNS:
```
REDACTED_HOSTNAME.REDACTED_DDNS      → IP_SERVER
immich.REDACTED_HOSTNAME.REDACTED_DDNS   → IP_SERVER  
jellyfin.REDACTED_HOSTNAME.REDACTED_DDNS     → IP_SERVER
plex.REDACTED_HOSTNAME.REDACTED_DDNS     → IP_SERVER
bitwarden.REDACTED_HOSTNAME.REDACTED_DDNS → IP_SERVER
```

## 📁 Struttura Directory

```
├── docker-compose.yml        # Stack principale con tutti i servizi
├── .env                      # Configurazione (da .env.example)
├── .env.example              # Template configurazione
├── deploy.sh                 # Script deploy automatico intelligente
├── utils.sh                  # Script utilità per gestione quotidiana
├── check.sh                  # Script verifica configurazione sistema
├── kickstart/                # Setup certificati SSL iniziali
│   ├── docker-compose.yaml
│   └── nginx.conf
└── data/                     # Dati persistenti (escluso da git)
    ├── nginx/
    ├── certbot/
    ├── immich/
    ├── jellyfin/
    └── plex/
   └── vaultwarden/
```

> **Backup offsite**: Tutto il contenuto di `data/` (escluso postgres, plex, syncthing) viene
> backuppato giornalmente su Proton Drive via Borg. Vedi `/mnt/nas2/nas-scripts/backup_offsite.sh`.

## 🔒 Sicurezza

- ✅ Certificati SSL automatici Let's Encrypt
- ✅ Redirect HTTP → HTTPS
- ✅ Headers di sicurezza configurati
- ✅ Servizi isolati in container Docker
- ✅ Password configurabili tramite .env

## 🚨 Troubleshooting

### Docker e Docker Compose
```bash
# Verifica versioni
docker --version
docker-compose --version

# Se hai errori di sintassi docker-compose (esempio: 'name' non supportato)
# Il progetto ora usa 'version: 3.8' per compatibilità con versioni Ubuntu LTS

# Test base Docker
docker run hello-world

# Se il deploy fallisce con errori EMAIL
source .env && echo $EMAIL  # Verifica che le variabili siano caricate
```

### Certificati SSL
```bash
# Verifica scadenza
openssl x509 -enddate -noout -in data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem

# Test connessione SSL
curl -I https://REDACTED_HOSTNAME.REDACTED_DDNS
```

### Jellyfin

```bash
# Verifica accesso directory media
ls -la /path/to/your/media
docker-compose exec jellyfin ls -la /media

# Verifica permessi utente
docker-compose exec jellyfin id

# Log Jellyfin per troubleshooting
docker-compose logs jellyfin
```

### JellyPlex-Watched

```bash
# Verifica configurazione e log
docker-compose logs jellyplex-watched

# Test connessione ai server (dal container)
./utils.sh sync test

# Controlla health status
docker-compose ps jellyplex-watched

# Riavvia solo il servizio di sync
./utils.sh sync restart

# Verifica che i server siano healthy prima dell'avvio
docker-compose ps | grep -E "(jellyfin|plex)" | grep healthy
```

### DNS

```bash
# Verifica risoluzione DNS
nslookup REDACTED_HOSTNAME.REDACTED_DDNS
nslookup immich.REDACTED_HOSTNAME.REDACTED_DDNS
nslookup jellyfin.REDACTED_HOSTNAME.REDACTED_DDNS
nslookup plex.REDACTED_HOSTNAME.REDACTED_DDNS
```

### Servizi
```bash
# Log specifico servizio
docker-compose logs immich-server
docker-compose logs nginx
docker-compose logs jellyfin

# Accesso shell container
docker-compose exec immich-server bash
```

### Port e Firewall
- Porta 80 (HTTP) deve essere accessibile per ACME challenges
- Porta 443 (HTTPS) per il traffico principale
- Porte 80/443 per debug locale

## 📚 Documentazione Servizi

- [Immich Documentation](https://immich.app/docs)
- [Jellyfin Documentation](https://jellyfin.org/docs/)
- [Plex Support](https://support.plex.tv/)
- [JellyPlex-Watched](https://github.com/luigi311/JellyPlex-Watched)
- [Nginx Documentation](https://nginx.org/en/docs/)

## 🎬 Configurazione Post-Deploy Jellyfin

Dopo il primo avvio di Jellyfin:

1. **Accedi a** https://jellyfin.REDACTED_HOSTNAME.REDACTED_DDNS
2. **Setup iniziale**: Crea utente amministratore
3. **Configurazione librerie**: Aggiungi le directory media configurate in .env
   - `/media` → i tuoi film/serie TV
   - `/media2` → musica/audiolibri (se configurato)
4. **Configurazione hardware transcoding** (opzionale): Per accelerazione GPU
5. **Configurazione utenti**: Crea utenti aggiuntivi se necessario

**Nota importante**: Se i file media non sono visibili, verifica permessi e percorsi nel file .env.

## 🔄 Configurazione JellyPlex-Watched (Sync Multi-Server)

Se utilizzi multiple piattaforme media (Jellyfin + Plex/Emby), JellyPlex-Watched mantiene sincronizzato automaticamente lo stato di visualizzazione:

### Setup Rapido
1. **Ottieni API Token Jellyfin**:
   - Vai su Dashboard → Advanced → API Keys
   - Crea nuova chiave API e copiala

2. **Ottieni API Token Plex** (se usi Plex):
   - Visita https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/
   - Copia il token X-Plex-Token

3. **Configura nel file .env**:
   ```bash
   # Modifica questi valori nel tuo .env
   JELLYFIN_TOKEN=il-tuo-token-jellyfin-api
   JELLYFIN_BASEURL=http://jellyfin:8096
   PLEX_TOKEN=il-tuo-token-plex-api
   PLEX_BASEURL=http://plex:32400
   ```

4. **Riavvia i servizi**:
   ```bash
   ./deploy.sh
   ```

5. **Verifica funzionamento**:
   ```bash
   ./utils.sh sync status
   ./utils.sh sync test
   ```

### Gestione
```bash
./utils.sh sync status    # Verifica stato sincronizzazione
./utils.sh sync logs      # Visualizza log di sincronizzazione  
./utils.sh sync test      # Test connessioni ai server media
```

**Cosa viene sincronizzato**:
- ✅ Stato "visto/non visto" tra server
- ✅ Progresso di visualizzazione parziale
- ✅ Mappatura automatica tramite nomi file
- ✅ Supporto multi-utente

**Frequenza**: Sincronizzazione automatica ogni ora (configurabile nel .env)

### 📱 Compatibilità Dispositivi Legacy

Jellyfin è configurato con supporto esteso per dispositivi più vecchi:

- **TLS 1.1/1.2/1.3**: Supporto per smart TV e dispositivi legacy
- **Cipher estesi**: Compatibilità con dispositivi che usano cifrature più vecchie
- **Timeout estesi**: 10 minuti per dispositivi più lenti
- **Upload 20GB**: Supporto per file media di grandi dimensioni

**Dispositivi testati**:
- Smart TV Samsung/LG (2015+)
- Apple TV (HD e 4K)
- Android TV / Fire TV
- Roku
- Chromecast

### 📱 Troubleshooting Client iOS

Se hai problemi con **Swiftfin**, **Jellyflix** o altri client iOS:

1. **Verifica la riproduzione diretta**: Disabilita transcoding nelle impostazioni Jellyfin per test
2. **Controlla i codec**: I client iOS preferiscono H.264/AAC in container MP4
3. **HLS ottimizzato**: La configurazione nginx include headers specifici per iOS
4. **Log di debug**: Controlla i log per `Stopped at 0 ms`:
   ```bash
   docker-compose logs jellyfin | grep "Stopped at 0 ms"
   ```
5. **Riavvia Jellyfin** se persistono problemi:
   ```bash
   docker-compose restart jellyfin
   ```

### 🔧 Problemi comuni e soluzioni

**"Unable to open stream.mkv"**:
- **Causa**: ID media obsoleto dopo refresh libreria
- **Soluzione**: Vai su Jellyfin Web → Dashboard → Libraries → Scan Library
- **App**: Pulisci cache o riaccedi nell'app

**"404 Not Found" per video**:
- **Causa**: File spostati o ID cambiati
- **Soluzione**: Refresh completo della libreria Jellyfin

## 🤝 Supporto

Per problemi o miglioramenti, controlla:
1. Log dei servizi: `./utils.sh logs`
2. Stato servizi: `./utils.sh status`
3. Configurazione DNS
4. Configurazione firewall/port forwarding
