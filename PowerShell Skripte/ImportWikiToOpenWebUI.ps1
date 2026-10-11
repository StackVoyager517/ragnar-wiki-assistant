

<#
Benötigt PowerShell Version 7, aufgrund der verwendeten Invoke-Webrequest Funktionalität 
Import die Markdown und dazugehörige Metadaten in den Wissensbestand von Open WebUI

#>



#Requires -Version 7.0

# Grundeinstellungen: Die beiden Verzeichnisse an deine Ablage anpassen.
# MetadataDirectory ist der Ausgabeordner des vorherigen Skripts.
$rootPath = "<Arbeitsverzeichnis>"
#Verzeichnis mit Metadaten Dateien
$MetadataDirectory = "$rootPath\<verzeichnis>"
#Verzeichnis mit Markdown Dateien
$MarkdownDirectory = "$rootPath\<verzeichnis>"
$BaseUrl = "<Open WebUI Base URL>"
#Name des Wissensbestands in Open WebUI
$KnowledgeName = "Prototyp_Wissensbestand"

# Zeitlimits: maximal 120 Sekunden pro API-Aufruf und 600 Sekunden
# fuer die Verarbeitung einer hochgeladenen Markdown-Datei.
$RequestTimeoutSeconds = 120
$ProcessingTimeoutSeconds = 600
$PollIntervalSeconds = 2

# StrictMode und Fehlerbehandlung wie in den bisherigen Skripten.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd("/")

# Pruefen, ob die benoetigten Verzeichnisse existieren.
if (-not (Test-Path -LiteralPath $MetadataDirectory -PathType Container)) {
    throw "Das Metadatenverzeichnis wurde nicht gefunden: $MetadataDirectory"
}

if (-not (Test-Path -LiteralPath $MarkdownDirectory -PathType Container)) {
    throw "Das Markdown-Verzeichnis wurde nicht gefunden: $MarkdownDirectory"
}

# Nur die neu erzeugten Metadatendateien sammeln, ohne Unterverzeichnisse.
# @() stellt auch bei einer einzigen Datei eine Liste bereit.
$metadataFiles = @(Get-ChildItem `
    -LiteralPath $MetadataDirectory `
    -Filter "*.metadata.json" `
    -File | Sort-Object Name)

if ($metadataFiles.Count -eq 0) {
    throw "Im Metadatenverzeichnis wurden keine *.metadata.json-Dateien gefunden."
}

# API-Schluessel verdeckt abfragen. Er wird nicht in das Skript oder Protokoll geschrieben.
# Fuer den Authorization-Header wird er anschliessend als Zeichenkette benoetigt.
$secureApiKey = Read-Host "Open WebUI API-Schluessel" -AsSecureString
$apiKey = [System.Net.NetworkCredential]::new("", $secureApiKey).Password
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "Es wurde kein API-Schluessel eingegeben."
}
$headers = @{ Authorization = "Bearer $apiKey"; Accept = "application/json" }

# Alle Seiten der Wissensbestand-Liste abrufen und den Namen exakt suchen.
# Open WebUI liefert pro Seite 'items' und die Gesamtzahl 'total'.
$knowledgeBases = @()
$page = 1
do {
    $response = Invoke-WebRequest `
        -Uri "$BaseUrl/api/v1/knowledge/?page=$page" `
        -Method Get -Headers $headers -TimeoutSec $RequestTimeoutSeconds
    $knowledgePage = $response.Content | ConvertFrom-Json
    $pageItems = @($knowledgePage.items)
    $knowledgeBases += $pageItems
    $page++
} while ($pageItems.Count -gt 0 -and $knowledgeBases.Count -lt $knowledgePage.total)

$matchingKnowledge = @($knowledgeBases | Where-Object { $_.name -ceq $KnowledgeName })
if ($matchingKnowledge.Count -ne 1) {
    throw "Der Name '$KnowledgeName' muss genau einmal vorhanden sein. Gefunden: $($matchingKnowledge.Count)."
}
if (-not $matchingKnowledge[0].write_access) {
    throw "Der Benutzer des API-Schluessels hat keinen Schreibzugriff auf '$KnowledgeName'."
}
$knowledgeId = $matchingKnowledge[0].id

# Vorhandene Dateinamen aus genau diesem Wissensbestand laden, ueber alle Seiten.
# Die Dateiliste hat einen eigenen Endpunkt; der Wissensbestand selbst enthaelt sie nicht.
# Gleichnamige Dateien werden uebersprungen; es erfolgt keine Aktualisierung.
$existingFiles = @()
$page = 1
do {
    $response = Invoke-WebRequest `
        -Uri "$BaseUrl/api/v1/knowledge/$knowledgeId/files?page=$page" `
        -Method Get -Headers $headers -TimeoutSec $RequestTimeoutSeconds
    $filePage = $response.Content | ConvertFrom-Json
    $pageItems = @($filePage.items)
    $existingFiles += $pageItems
    $page++
} while ($pageItems.Count -gt 0 -and $existingFiles.Count -lt $filePage.total)
$existingFileNames = @($existingFiles | ForEach-Object { $_.filename })

Write-Host "Wissensbestand: $KnowledgeName"
Write-Host "Knowledge-ID:   $knowledgeId"
Write-Host "Dateipaare:     $($metadataFiles.Count)"
Write-Host ""

# Zaehler und Ergebnisliste fuer die abschliessende Auswertung vorbereiten.
$processedCount = 0
$skippedCount = 0
$errorCount = 0
$results = @()

foreach ($metadataFile in $metadataFiles) {
    # Aus 13122.metadata.json den zugehoerigen Namen 13122.md ableiten.
    $markdownFileName = $metadataFile.Name -replace '\.metadata\.json$', '.md'
    $markdownFilePath = Join-Path -Path $MarkdownDirectory -ChildPath $markdownFileName
    $fileId = ""
    $importStatus = "Fehler"
    $errorMessage = ""

    try {
        # Bereits vorhandene Dateien nicht erneut importieren.
        if ($existingFileNames -contains $markdownFileName) {
            $skippedCount++
            $importStatus = "Uebersprungen"
            Write-Host "Bereits vorhanden: $markdownFileName"
            continue
        }

        # Pruefen, ob die passende Markdown-Datei vorhanden ist.
        if (-not (Test-Path -LiteralPath $markdownFilePath -PathType Leaf)) {
            throw "Die zugehoerige Markdown-Datei wurde nicht gefunden: $markdownFilePath"
        }

        # Metadaten lesen und die vier erforderlichen Felder pruefen.
        $metadataJson = [System.IO.File]::ReadAllText(
            $metadataFile.FullName, [System.Text.Encoding]::UTF8
        )
        $metadata = $metadataJson | ConvertFrom-Json
        foreach ($fieldName in @("title", "source_url", "revision_id", "revision_timestamp")) {
            if ($null -eq $metadata -or
                ($metadata.PSObject.Properties.Name -notcontains $fieldName) -or
                [string]::IsNullOrWhiteSpace([string]$metadata.$fieldName)) {
                throw "Das Metadatenfeld '$fieldName' fehlt oder ist leer."
            }
        }

        Write-Host "Importiere: $markdownFileName"

        # Schritt 1: Markdown als Datei und JSON als Textfeld gemeinsam hochladen.
        # Get-Item liefert das fuer -Form benoetigte FileInfo-Objekt.
        # Das JSON wird unveraendert gesendet, einschliesslich des Zeitstempels.
        # Den multipart Content-Type setzt Invoke-WebRequest automatisch.
        $response = Invoke-WebRequest `
            -Uri "$BaseUrl/api/v1/files/" `
            -Method Post -Headers $headers -TimeoutSec $RequestTimeoutSeconds `
            -Form @{
                file     = (Get-Item -LiteralPath $markdownFilePath)
                metadata = $metadataJson
            }
        $uploadedFile = $response.Content | ConvertFrom-Json
        $fileId = [string]$uploadedFile.id
        if ([string]::IsNullOrWhiteSpace($fileId)) {
            throw "Die Upload-Antwort enthaelt keine Datei-ID."
        }

        # Schritt 2: Auf abgeschlossene Verarbeitung warten.
        # Open WebUI verwendet seine konfigurierten Chunking- und Embedding-Einstellungen.
        # Erst nach 'completed' darf die Datei zum Wissensbestand hinzugefuegt werden.
        $waitTimer = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($waitTimer.Elapsed.TotalSeconds -ge $ProcessingTimeoutSeconds) {
                throw "Verarbeitung nach $ProcessingTimeoutSeconds Sekunden nicht abgeschlossen."
            }
            $response = Invoke-WebRequest `
                -Uri "$BaseUrl/api/v1/files/$fileId/process/status" `
                -Method Get -Headers $headers -TimeoutSec $RequestTimeoutSeconds
            $processing = $response.Content | ConvertFrom-Json

            if ($processing.status -eq "completed") {
                break
            }
            if ($processing.status -eq "failed") {
                throw "Open WebUI meldet eine fehlgeschlagene Dateiverarbeitung. Siehe die Container-Logs."
            }
            Start-Sleep -Seconds $PollIntervalSeconds
        }

        # Schritt 3: Die verarbeitete Datei dem bereits erstellten Wissensbestand zuordnen.
        # Die Metadaten sind ueber die Datei-ID weiterhin mit dem Markdown verbunden.
        $body = @{ file_id = $fileId } | ConvertTo-Json
        $response = Invoke-WebRequest `
            -Uri "$BaseUrl/api/v1/knowledge/$knowledgeId/file/add" `
            -Method Post -Headers $headers -TimeoutSec $RequestTimeoutSeconds `
            -ContentType "application/json" -Body $body
        $updatedKnowledge = $response.Content | ConvertFrom-Json

        # Die Antwort muss die neue Datei in der Dateiliste des Wissensbestands enthalten.
        $linkedFiles = @($updatedKnowledge.files | Where-Object { $_.id -eq $fileId })
        if ($linkedFiles.Count -eq 0) {
            throw "Die Datei-ID fehlt in der Dateiliste der Zuordnungsantwort."
        }

        # Den Namen merken und den erfolgreichen Import zaehlen.
        $existingFileNames += $markdownFileName
        $processedCount++
        $importStatus = "Importiert"
        Write-Host "Erfolgreich importiert: $markdownFileName (Datei-ID: $fileId)"
    }
    catch {
        # Fehler je Datei protokollieren und mit der naechsten Datei fortfahren.
        # ErrorDetails enthaelt bei HTTP-Fehlern haeufig die Antwort der API.
        $errorCount++
        $errorMessage = $_.Exception.Message
        if ($null -ne $_.ErrorDetails) {
            $errorMessage += " " + $_.ErrorDetails.Message
        }
        Write-Warning "$markdownFileName (Datei-ID: $fileId): $errorMessage"
    }
    finally {
        # Fuer jeden Versuch einen Protokolleintrag anlegen, auch beim Ueberspringen.
        # Eine Datei-ID bei einem Fehler hilft, einen teilweise erfolgten Upload zu finden.
        $results += [PSCustomObject]@{
            Metadatendatei = $metadataFile.Name
            Markdowndatei = $markdownFileName
            DateiID = $fileId
            Status = $importStatus
            Fehler = $errorMessage
        }
    }
}

# Das Protokoll ohne API-Schluessel als CSV im Stammordner speichern.
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$logPath = Join-Path -Path $rootPath -ChildPath "openwebui_import_$timestamp.csv"
$results | Export-Csv -LiteralPath $logPath -Delimiter ';' -NoTypeInformation -Encoding utf8BOM

# Ergebnisse wie in den bisherigen Skripten zusammenfassen.
Write-Host ""
Write-Host "Auswertung des Open-WebUI-Imports"
Write-Host "--------------------------------"
Write-Host "Gefundene Metadatendateien: $($metadataFiles.Count)"
Write-Host "Erfolgreich importiert:     $processedCount"
Write-Host "Bereits vorhanden:          $skippedCount"
Write-Host "Fehler:                     $errorCount"
Write-Host "Protokoll:                  $logPath"

# Teilweise erfolgreiche Importe bleiben erhalten. Bei Fehlern den Durchlauf melden.
if ($errorCount -gt 0) {
    throw "Bei $errorCount Dateipaar(en) trat ein Fehler auf. Details: $logPath"
}
