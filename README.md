# 📦 SmartFolder Archiver

Backup e compressione di cartelle con 7-Zip, GUI Matrix e auto-installazione.

## ✨ Feature

- ✅ **Modalità Singola**: comprime un'intera cartella in un unico archivio `.7z` con timestamp.
- ✅ **Modalità Sottocartelle**: scegli quali sottocartelle comprimere (e se includere i file della root) tramite una lista di checkbox.
- ✅ **Backup Incrementale**: aggiorna un archivio esistente aggiungendo solo i file nuovi o modificati.
- ✅ **Auto-Installazione 7-Zip**: se non hai 7-Zip, il tool lo scarica e installa in background.
- ✅ **Auto-Elevazione Admin**: richiede i permessi necessari per l'installazione e l'accesso.
- ✅ **Pulsante ANNULLA**: ferma la compressione in qualsiasi momento.
- ✅ **Log su file**: traccia tutte le operazioni.

## 📋 Requisiti

- **Windows 10 / 11**
- **PowerShell 7+** (scarica da https://aka.ms/powershell)
- **Connessione internet** (solo per il primo avvio, per scaricare 7-Zip)

## 🚀 Quick start

```powershell
git clone https://github.com/fabrytoolbox/SmartFolder-Archiver.git
cd SmartFolder-Archiver
Unblock-File .\SmartFolder-Archiver.ps1
.\SmartFolder-Archiver.ps1

Oppure doppio click su avvia.bat.

🎯 Casi d'uso
Backup di progetto: comprimi una cartella di lavoro con timestamp.

Backup selettivo: comprimi solo le cartelle che ti interessano (es. Documenti e Foto, ma non Cache).

Backup incrementale: aggiorna un archivio esistente con le ultime modifiche, senza rifare tutto da capo.

Archiviazione: crea archivi .7z compressi al massimo per risparmiare spazio.

⚙️ Come funziona
Seleziona la cartella principale.

Seleziona la destinazione (o usa la stessa).

Scegli la modalità (Singola, Sottocartelle, Incrementale).

Avvia.

🐛 Problemi comuni
"7-Zip non trovato"
Il tool chiede se scaricarlo e installarlo automaticamente. Se fallisce, installalo manualmente da https://www.7-zip.org/

"Il backup incrementale crea file enormi"
Assicurati che l'archivio di destinazione non si trovi dentro la cartella che stai comprimendo (il tool esclude automaticamente il file, ma è meglio evitare).

📜 Licenza
MIT (vedi LICENSE).

🙏 Crediti
7-Zip per la compressione

Fabry Toolbox