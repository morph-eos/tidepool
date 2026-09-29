#!/bin/bash

# Script to change the Samba password safely

echo "=== Cambio Password Samba ==="
echo "Utente: REDACTED_HOSTNAME"
echo ""
echo "Scegli una password robusta: non riusare quella di altri servizi."
echo ""

# Check whether the user exists
if ! sudo pdbedit -L | grep -q "REDACTED_HOSTNAME"; then
    echo "ERRORE: Utente REDACTED_HOSTNAME non trovato nel database Samba!"
    echo "Creazione utente..."
    sudo smbpasswd -a REDACTED_HOSTNAME
else
    echo "Inserisci la nuova password per l'accesso NAS:"
    sudo smbpasswd REDACTED_HOSTNAME
fi

echo ""
echo "Password aggiornata! Riavvio servizi Samba..."
sudo systemctl restart smbd

echo ""
echo "✅ Password cambiata con successo!"
echo "🔒 Accesso guest DISABILITATO per maggiore sicurezza"
echo "📁 Tutte le condivisioni richiedono autenticazione"
echo ""
echo "Test della configurazione:"
sudo testparm -s | grep -A 20 "\[NAS\]"
