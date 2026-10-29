# SmartFolder-Archiver.ps1 - v5.0 (7-Zip Edition)
# Compressore di cartelle con 7-Zip (Singola, Multipla, Incrementale, Selettiva)
# Auto-Elevazione, Auto-Installazione 7-Zip, GUI Matrix, Log

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================
# AUTO-ELEVAZIONE ADMIN
# ============================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show("Rilancio come Amministratore per consentire l'installazione di 7-Zip e l'accesso alle cartelle di sistema...", "Richiesta Privilegi", "OK", "Information")
    
    $pwshPath = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path $pwshPath)) { $pwshPath = "pwsh.exe" }
    
    Start-Process $pwshPath -ArgumentList "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$script:workDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:logFile = $null
$script:7zPath = $null
$script:currentProcess = $null
$script:isWorking = $false
$script:targetArchivePath = $null

# ============================================
# AUTO-INSTALLAZIONE 7-ZIP
# ============================================
function Initialize-7Zip {
    $paths = @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }

    $resp = [System.Windows.Forms.MessageBox]::Show(
        "7-Zip non trovato. Vuoi scaricarlo e installarlo automaticamente? (Richiede connessione internet)", 
        "7-Zip Missing", 
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    )
    if ($resp -eq "No") { return $null }

    $installerPath = Join-Path $env:TEMP "7z_installer.exe"
    # Link ufficiale per la versione x64
    $url = "https://www.7-zip.org/a/7z2408-x64.exe"
    
    try {
        Write-Host "Download 7-Zip in corso..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing
        
        Write-Host "Installazione silenziosa..." -ForegroundColor Cyan
        # /S per installazione silenziosa
        $proc = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
        
        if ($proc.ExitCode -eq 0) {
            Write-Host "[OK] 7-Zip installato." -ForegroundColor Green
            foreach ($p in $paths) { if (Test-Path $p) { return $p } }
            return $null
        } else {
            [System.Windows.Forms.MessageBox]::Show("Installazione fallita (ExitCode: $($proc.ExitCode))")
            return $null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Errore download/installazione: $($_.Exception.Message)")
        return $null
    } finally {
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    }
}

# ============================================
# LOGGING
# ============================================
function Start-Log {
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:logFile = Join-Path $script:workDir "SmartArchiver_$ts.log"
    "--- SMART ARCHIVER LOG (7-Zip) ---" | Set-Content -Path $script:logFile -Encoding UTF8
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if ($txtLog) {
        $txtLog.AppendText("$line`r`n")
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($script:logFile) {
        Add-Content -Path $script:logFile -Value $line -Encoding UTF8
    }
}

# ============================================
# FUNZIONI CORE DI COMPRESSIONE (7-Zip)
# ============================================
function Compress-SingleFolder {
    param([string]$FolderPath, [string]$OutputDir, [string]$BaseName, [switch]$Incremental)
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    
    if ($Incremental) {
        $archiveFile = $script:targetArchivePath
        # Per l'incrementale (update), 7-Zip usa semplicemente 'a' (add) su un file esistente
        Write-Log "Modalita INCREMENTALE su: $(Split-Path $archiveFile -Leaf)" "INFO"
    } else {
        $archiveFile = Join-Path $OutputDir "$($BaseName)_$timestamp.7z"
        Write-Log "Modalita CREA NUOVO: $(Split-Path $archiveFile -Leaf)" "INFO"
    }
    
    # a = add, -t7z = formato 7z, -mx=9 = massima compressione
    $args = @("a", "-t7z", "-mx=9", "`"$archiveFile`"", "`"$FolderPath\*`"")
    
    try {
        $script:currentProcess = Start-Process -FilePath $script:7zPath -ArgumentList $args -PassThru -WindowStyle Hidden
        
        while (-not $script:currentProcess.HasExited) {
            if (-not $script:isWorking) {
                $script:currentProcess.Kill()
                Write-Log "Processo annullato dall'utente." "WARNING"
                return $false
            }
            Start-Sleep -Milliseconds 200
        }
        
        if ($script:currentProcess.ExitCode -eq 0) {
            Write-Log "OK: $(Split-Path $archiveFile -Leaf)" "OK"
            return $true
        } else {
            Write-Log "ERRORE (ExitCode $($script:currentProcess.ExitCode)): $(Split-Path $archiveFile -Leaf)" "ERROR"
            return $false
        }
    } catch {
        Write-Log "ECCEZIONE: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Compress-SubFolders {
    param([string]$MainFolder, [string]$OutputDir, [string]$BaseName, [array]$SelectedFolders)
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $targetFolder = Join-Path $OutputDir "Backup_$($BaseName)_$timestamp"
    
    if (-not (Test-Path $targetFolder)) {
        New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
    }
    
    Write-Log "Cartella backup creata: $targetFolder" "INFO"
    
    $total = $SelectedFolders.Count + 1
    $current = 0
    $success = 0
    $failed = 0
    
    # --- 1. BACKUP DEI FILE NELLA ROOT (SOLO FILE, NIENTE CARTELLE) ---
    $rootFiles = Get-ChildItem -Path $MainFolder -File -Recurse:$false
    if ($rootFiles.Count -gt 0) {
        $current++
        $progressBar.Value = [math]::Round(($current / $total) * 100, 1)
        $form.Text = "COMPRESSIONE: Radice ($current/$total)"
        [System.Windows.Forms.Application]::DoEvents()
        
        $rootArchive = Join-Path $targetFolder "$BaseName.7z"
        
        # 7-Zip: -xr!*/ esclude ricorsivamente tutte le cartelle
        $args = @("a", "-t7z", "-mx=9", "`"$rootArchive`"", "`"$MainFolder\*`"", "-xr!*/")
        
        try {
            $script:currentProcess = Start-Process -FilePath $script:7zPath -ArgumentList $args -PassThru -WindowStyle Hidden
            while (-not $script:currentProcess.HasExited) {
                if (-not $script:isWorking) { $script:currentProcess.Kill(); break }
                Start-Sleep -Milliseconds 200
            }
            if ($script:currentProcess.ExitCode -eq 0) {
                Write-Log "OK: File radice compattati in $BaseName.7z" "OK"
                $success++
            } else {
                Write-Log "ERRORE: File radice (ExitCode $($script:currentProcess.ExitCode))" "ERROR"
                $failed++
            }
        } catch {
            Write-Log "ECCEZIONE: File radice - $($_.Exception.Message)" "ERROR"
            $failed++
        }
    } else {
        Write-Log "Nessun file sciolto nella radice." "INFO"
    }

    # --- 2. BACKUP DELLE SOTTOCARTELLE SELEZIONATE ---
    foreach ($subFolder in $SelectedFolders) {
        if (-not $script:isWorking) { break }
        
        $current++
        $percent = [math]::Round(($current / $total) * 100, 1)
        
        $progressBar.Value = $percent
        $form.Text = "COMPRESSIONE: $($subFolder.Name) ($current/$total)"
        [System.Windows.Forms.Application]::DoEvents()
        
        $safeName = $subFolder.Name -replace '[\\/:*?"<>|]', '_'
        $archiveFile = Join-Path $targetFolder "$safeName.7z"
        
        $args = @("a", "-t7z", "-mx=9", "`"$archiveFile`"", "`"$($subFolder.FullName)\*`"")
        
        try {
            $script:currentProcess = Start-Process -FilePath $script:7zPath -ArgumentList $args -PassThru -WindowStyle Hidden
            while (-not $script:currentProcess.HasExited) {
                if (-not $script:isWorking) { $script:currentProcess.Kill(); break }
                Start-Sleep -Milliseconds 200
            }
            if ($script:currentProcess.ExitCode -eq 0) {
                Write-Log "OK: $($subFolder.Name)" "OK"
                $success++
            } else {
                Write-Log "ERRORE: $($subFolder.Name) (ExitCode $($script:currentProcess.ExitCode))" "ERROR"
                $failed++
            }
        } catch {
            Write-Log "ECCEZIONE: $($subFolder.Name) - $($_.Exception.Message)" "ERROR"
            $failed++
        }
    }
    
    $progressBar.Value = 0
    $form.Text = "SMART FOLDER ARCHIVER - MATRIX CORE"
    Write-Log "RIEPILOGO: $success successi, $failed fallimenti." "INFO"
}

# ============================================
# GUI MATRIX
# ============================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "SMART FOLDER ARCHIVER - MATRIX CORE (7-Zip)"
$form.Size = New-Object System.Drawing.Size(700, 820)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::Black
$form.ForeColor = [System.Drawing.Color]::Lime
$form.Font = New-Object System.Drawing.Font("Consolas", 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "SMART FOLDER ARCHIVER"
$lblTitle.Font = New-Object System.Drawing.Font("Consolas", 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.TextAlign = "MiddleCenter"
$lblTitle.Location = New-Object System.Drawing.Point(20, 10)
$lblTitle.Size = New-Object System.Drawing.Size(640, 30)
$form.Controls.Add($lblTitle)

# --- Selezione Cartella ---
$btnSelect = New-Object System.Windows.Forms.Button
$btnSelect.Text = "1. SELEZIONA CARTELLA"
$btnSelect.Location = New-Object System.Drawing.Point(20, 60)
$btnSelect.Size = New-Object System.Drawing.Size(200, 35)
$btnSelect.FlatStyle = "Flat"
$btnSelect.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$form.Controls.Add($btnSelect)

$lblPath = New-Object System.Windows.Forms.Label
$lblPath.Text = "Nessuna cartella selezionata"
$lblPath.Location = New-Object System.Drawing.Point(230, 68)
$lblPath.Size = New-Object System.Drawing.Size(430, 20)
$lblPath.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($lblPath)

# --- Destinazione ---
$btnDest = New-Object System.Windows.Forms.Button
$btnDest.Text = "2. DESTINAZIONE"
$btnDest.Location = New-Object System.Drawing.Point(20, 105)
$btnDest.Size = New-Object System.Drawing.Size(200, 35)
$btnDest.FlatStyle = "Flat"
$btnDest.FlatAppearance.BorderColor = [System.Drawing.Color]::Lime
$form.Controls.Add($btnDest)

$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = "Nessuna destinazione (usa la cartella stessa)"
$lblDest.Location = New-Object System.Drawing.Point(230, 113)
$lblDest.Size = New-Object System.Drawing.Size(430, 20)
$lblDest.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($lblDest)

# --- Opzioni ---
$gbOpt = New-Object System.Windows.Forms.GroupBox
$gbOpt.Text = "3. MODALITÀ"
$gbOpt.ForeColor = [System.Drawing.Color]::Lime
$gbOpt.Location = New-Object System.Drawing.Point(20, 160)
$gbOpt.Size = New-Object System.Drawing.Size(640, 140)
$form.Controls.Add($gbOpt)

$rbSingle = New-Object System.Windows.Forms.RadioButton
$rbSingle.Text = "Singola Cartella (un archivio .7z con timestamp)"
$rbSingle.Location = New-Object System.Drawing.Point(20, 25)
$rbSingle.Size = New-Object System.Drawing.Size(500, 20)
$rbSingle.Checked = $true
$gbOpt.Controls.Add($rbSingle)

$rbSub = New-Object System.Windows.Forms.RadioButton
$rbSub.Text = "Sottocartelle Selezionate (scegli quali comprimere)"
$rbSub.Location = New-Object System.Drawing.Point(20, 55)
$rbSub.Size = New-Object System.Drawing.Size(500, 20)
$gbOpt.Controls.Add($rbSub)

$chkIncremental = New-Object System.Windows.Forms.CheckBox
$chkIncremental.Text = "Backup Incrementale (aggiorna un archivio .7z esistente)"
$chkIncremental.Location = New-Object System.Drawing.Point(20, 85)
$chkIncremental.Size = New-Object System.Drawing.Size(500, 20)
$chkIncremental.ForeColor = [System.Drawing.Color]::Yellow
$gbOpt.Controls.Add($chkIncremental)

# --- Lista Selezione Sottocartelle ---
$lblSubList = New-Object System.Windows.Forms.Label
$lblSubList.Text = "Seleziona le sottocartelle da includere:"
$lblSubList.Location = New-Object System.Drawing.Point(20, 310)
$lblSubList.Size = New-Object System.Drawing.Size(400, 20)
$lblSubList.Visible = $false
$form.Controls.Add($lblSubList)

$clbSubFolders = New-Object System.Windows.Forms.CheckedListBox
$clbSubFolders.Location = New-Object System.Drawing.Point(20, 335)
$clbSubFolders.Size = New-Object System.Drawing.Size(640, 120)
$clbSubFolders.BackColor = [System.Drawing.Color]::Black
$clbSubFolders.ForeColor = [System.Drawing.Color]::Lime
$clbSubFolders.BorderStyle = "FixedSingle"
$clbSubFolders.CheckOnClick = $true
$clbSubFolders.Visible = $false
$form.Controls.Add($clbSubFolders)

# --- Avvio e Annullamento ---
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = ">> AVVIA COMPRESSIONE <<"
$btnStart.Location = New-Object System.Drawing.Point(20, 470)
$btnStart.Size = New-Object System.Drawing.Size(400, 45)
$btnStart.BackColor = "DarkGreen"
$btnStart.ForeColor = [System.Drawing.Color]::Lime
$btnStart.Font = New-Object System.Drawing.Font("Consolas", 12, [System.Drawing.FontStyle]::Bold)
$btnStart.FlatStyle = "Flat"
$form.Controls.Add($btnStart)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "ANNULLA"
$btnCancel.Location = New-Object System.Drawing.Point(440, 470)
$btnCancel.Size = New-Object System.Drawing.Size(220, 45)
$btnCancel.BackColor = "DarkRed"
$btnCancel.ForeColor = [System.Drawing.Color]::White
$btnCancel.Font = New-Object System.Drawing.Font("Consolas", 12, [System.Drawing.FontStyle]::Bold)
$btnCancel.FlatStyle = "Flat"
$btnCancel.Visible = $false
$form.Controls.Add($btnCancel)

# --- Progress Bar ---
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 530)
$progressBar.Size = New-Object System.Drawing.Size(640, 20)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$form.Controls.Add($progressBar)

# --- Log ---
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Location = New-Object System.Drawing.Point(20, 560)
$txtLog.Size = New-Object System.Drawing.Size(640, 200)
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$txtLog.ForeColor = [System.Drawing.Color]::Lime
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.BorderStyle = "FixedSingle"
$form.Controls.Add($txtLog)

# ============================================
# VARIABILI DI STATO
# ============================================
$script:selectedPath = $null
$script:destPath = $null

# ============================================
# EVENTI
# ============================================
$btnSelect.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Seleziona la cartella principale da comprimere"
    if ($dlg.ShowDialog() -eq "OK") {
        $script:selectedPath = $dlg.SelectedPath
        $lblPath.Text = $script:selectedPath
        $lblPath.ForeColor = [System.Drawing.Color]::Lime
        
        $script:destPath = $null
        $lblDest.Text = "Nessuna destinazione (usa la cartella stessa)"
        $lblDest.ForeColor = [System.Drawing.Color]::White
        
        $clbSubFolders.Items.Clear()
        
        # Aggiungi la ROOT come primo elemento (con un'etichetta chiara)
        [void]$clbSubFolders.Items.Add("[ROOT] $($script:selectedPath) (solo file sciolti)", $true)
        
        # Aggiungi le sottocartelle
        $subDirs = Get-ChildItem -Path $script:selectedPath -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $subDirs) {
            [void]$clbSubFolders.Items.Add($dir.Name, $true)
        }
        
        Write-Log "Cartella sorgente: $($script:selectedPath)" "INFO"
    }
})

$btnDest.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Seleziona la cartella dove salvare i backup"
    $dlg.ShowNewFolderButton = $true
    
    if ($dlg.ShowDialog() -eq "OK") {
        $script:destPath = $dlg.SelectedPath
        $lblDest.Text = $script:destPath
        $lblDest.ForeColor = [System.Drawing.Color]::Lime
        Write-Log "Destinazione impostata: $($script:destPath)" "INFO"
    } else {
        Write-Log "Selezione destinazione annullata." "WARNING"
    }
})

$rbSub.Add_CheckedChanged({
    if ($rbSub.Checked) {
        $lblSubList.Visible = $true
        $clbSubFolders.Visible = $true
    } else {
        $lblSubList.Visible = $false
        $clbSubFolders.Visible = $false
    }
})

$chkIncremental.Add_CheckedChanged({
    if ($chkIncremental.Checked) {
        $rbSingle.Checked = $true
        $rbSub.Enabled = $false
    } else {
        $rbSub.Enabled = $true
    }
})

$btnStart.Add_Click({
    if (-not $script:selectedPath) {
        [System.Windows.Forms.MessageBox]::Show("Seleziona una cartella sorgente!", "Errore")
        return
    }
    
    $dest = if ($script:destPath) { $script:destPath } else { $script:selectedPath }
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    
    $baseName = Split-Path $script:selectedPath -Leaf
    
    if ($chkIncremental.Checked) {
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = "Archivio 7-Zip (*.7z)|*.7z"
        $dlg.FileName = "$($baseName)_INCREMENTALE.7z"
        $dlg.InitialDirectory = $dest
        
        if ($dlg.ShowDialog() -ne "OK") { return }
        $script:targetArchivePath = $dlg.FileName
    }
    
    $selectedDirs = @()
    if ($rbSub.Checked) {
        foreach ($item in $clbSubFolders.CheckedItems) {
            $selectedDirs += Get-Item (Join-Path $script:selectedPath $item)
        }
        if ($selectedDirs.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Seleziona almeno una sottocartella!", "Errore")
            return
        }
    }
    
    $script:isWorking = $true
    $btnStart.Visible = $false
    $btnCancel.Visible = $true
    $txtLog.Clear()
    
    Start-Log
    Write-Log "Avvio compressione..." "INFO"
    
    if ($rbSingle.Checked) {
        Compress-SingleFolder -FolderPath $script:selectedPath -OutputDir $dest -BaseName $baseName -Incremental:$chkIncremental.Checked | Out-Null
    } else {
        Compress-SubFolders -MainFolder $script:selectedPath -OutputDir $dest -BaseName $baseName -SelectedFolders $selectedDirs
    }
    
    if ($script:isWorking) {
        Write-Log "Operazione completata." "OK"
        [System.Windows.Forms.MessageBox]::Show("Compressione completata!`n`nLog: $($script:logFile)", "Fatto")
    }
    
    $script:isWorking = $false
    $btnStart.Visible = $true
    $btnCancel.Visible = $false
})

$btnCancel.Add_Click({
    $script:isWorking = $false
    Write-Log "Richiesta annullamento..." "WARNING"
})

# ============================================
# AVVIO
# ============================================
$script:7zPath = Initialize-7Zip

if (-not $script:7zPath) {
    [System.Windows.Forms.MessageBox]::Show("Impossibile procedere senza 7-Zip. Installalo manualmente da https://www.7-zip.org/", "Errore Critico")
    exit
}

$form.ShowDialog() | Out-Null