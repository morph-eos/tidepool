#!/bin/bash

# Script principale per configurare l'intera installazione NAS + Time Machine

set -e

echo "=== Setup completo NAS + Time Machine ==="
echo "Questo script configurerà:"
echo "- Partizionamento disco da 16TB (NAS + Time Machine)"
echo "- Partizionamento disco da 1TB (NAS2)"
echo "- Partizione NAS come prima partizione (13TB)"
echo "- Partizione Time Machine da 3TB come seconda partizione"
echo "- Partizione NAS2 da 1TB"
echo "- Servizi Samba (SMB/CIFS)"
echo "- Discovery automatico tramite Avahi"
echo ""
echo "NOTA: Lo script è intelligente e configurerà solo quello che manca"
echo ""

# Controllo modalità esecuzione
if [ "$1" = "--force" ]; then
    echo "Modalità automatica attivata..."
    sleep 2
else
    echo "Premi CTRL+C per annullare, altrimenti premi INVIO per continuare..."
    echo "Oppure usa './setup_complete.sh --force' per esecuzione automatica"
    read
fi

echo "1. Configurazione dischi intelligente..."
bash ./setup_disk.sh "$1"

echo "2. Configurazione Samba..."
bash ./setup_samba.sh

echo "3. Verifica servizi..."
echo "Stato Samba:"
sudo systemctl status smbd --no-pager -l
echo ""
echo "Stato Avahi:"
sudo systemctl status avahi-daemon --no-pager -l

echo "4. Informazioni di connessione..."
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo ""
echo "=== CONFIGURAZIONE COMPLETATA! ==="
echo ""
echo "Il tuo NAS è ora accessibile tramite:"
echo "📁 NAS (SMB): \\\\$IP_ADDRESS\\NAS"
echo "📁 NAS2 (SMB): \\\\$IP_ADDRESS\\NAS2"
echo "⏰ Time Machine (SMB): \\\\$IP_ADDRESS\\TimeMachine"
echo ""
echo "Credenziali:"
echo "- Utente: REDACTED_HOSTNAME"
echo "- Password predefinita: REDACTED_DEFAULT_PASSWORD"
echo "- ⚠️  CAMBIA LA PASSWORD: sudo smbpasswd REDACTED_HOSTNAME"
echo ""
echo "Punti di mount locali:"
echo "- NAS: /mnt/nas (prima partizione 13TB)"
echo "- Time Machine: /mnt/timemachine (seconda partizione 3TB)"
echo "- NAS2: /mnt/nas2 (1TB)"
echo ""
echo "Per macOS Time Machine:"
echo "1. Vai su Preferenze di Sistema > Time Machine"
echo "2. Scegli disco e seleziona il server '$HOSTNAME'"
echo "3. Seleziona il volume 'TimeMachine'"
echo "4. Inserisci le credenziali quando richiesto"
echo ""
echo "🛠️  Comandi utili:"
echo "- Stato sistema: ./nas_status.sh"
echo "- Cambia password: ./change_password.sh"
echo "- Informazioni complete: ./nas_info.sh"
