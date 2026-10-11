
<#

Excludiert Artikel mit nicht geeignerten Tabellenformaten vor der Konvertierung durch die MarkItDown Komponente 
Setzt Status in den Metadaten 

#>

# Arbeitsverzeichnis angeben
$rootPath = "<Arbeitsverzeichnis>"
$MetadataDirectory = "$rootPath\metadaten"
$HtmlDirectory = "$rootPath\raw\html"
 

# StrictMode - Best practice für weniger Fehleranfälligkeit
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Erwartete Anzahl der Artikel mit rowspan oder colspan - Variable entsprechend dem nachfolgendem Abschnitt setzen 
$expectedExcludedCount = 46

#Anzahl der Artikel zuvor bereits mit diesem Skriptblock abefragt
<#
$tables= Get-ChildItem "$rootPath\raw\html\*.html" | Where-Object {
    Select-String -Path $_.FullName -Pattern 'rowspan=|colspan=' -Quiet}
    #>

# Prüfen, ob die benötigten Verzeichnisse existieren
if (-not (Test-Path -LiteralPath $MetadataDirectory -PathType Container)) {
    throw "Das Metadatenverzeichnis wurde nicht gefunden: $MetadataDirectory"
}

if (-not (Test-Path -LiteralPath $HtmlDirectory -PathType Container)) {
    throw "Das HTML-Verzeichnis wurde nicht gefunden: $HtmlDirectory"
}

$metadataFiles = Get-ChildItem `
    -LiteralPath $MetadataDirectory `
    -Filter "*.json" `
    -File

if ($metadataFiles.Count -eq 0) {
    throw "Im Metadatenverzeichnis wurden keine JSON-Dateien gefunden."
}

# Sicherungskopie vor der Änderung erstellen
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$metadataParentDirectory = Split-Path -Path $MetadataDirectory -Parent
$backupDirectory = Join-Path `
    -Path $metadataParentDirectory `
    -ChildPath "metadaten_backup_$timestamp"

New-Item `
    -Path $backupDirectory `
    -ItemType Directory `
    -Force | Out-Null

Copy-Item `
    -Path (Join-Path $MetadataDirectory "*.json") `
    -Destination $backupDirectory `
    -Force

Write-Host "Sicherung der Metadaten erstellt:"
Write-Host $backupDirectory
Write-Host ""

# UTF-8 ohne BOM verwenden
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

$processedCount = 0
$includedCount = 0
$excludedCount = 0
$errorCount = 0
$excludedArticles = @()

foreach ($metadataFile in $metadataFiles) {
    try {
        # JSON-Metadaten einlesen
        $jsonContent = [System.IO.File]::ReadAllText(
            $metadataFile.FullName,
            [System.Text.Encoding]::UTF8
        )

        $metadata = $jsonContent | ConvertFrom-Json

        if ($null -eq $metadata.files) {
            throw "Das Objekt 'files' fehlt."
        }

        if ($null -eq $metadata.conversion) {
            throw "Das Objekt 'conversion' fehlt."
        }

        $htmlFileName = [string]$metadata.files.html_file

        if ([string]::IsNullOrWhiteSpace($htmlFileName)) {
            throw "Im Feld 'files.html_file' ist keine HTML-Datei angegeben."
        }

        $htmlFilePath = Join-Path `
            -Path $HtmlDirectory `
            -ChildPath $htmlFileName

        if (-not (Test-Path -LiteralPath $htmlFilePath -PathType Leaf)) {
            throw "Die zugehörige HTML-Datei wurde nicht gefunden: $htmlFilePath"
        }

        # HTML-Datei einlesen
        $htmlContent = [System.IO.File]::ReadAllText(
            $htmlFilePath,
            [System.Text.Encoding]::UTF8
        )

        # Dasselbe Prüfkriterium wie in der vorherigen PowerShell-Abfrage
        $hasMergedTableCells = $htmlContent -match `
            '(?i)\b(?:rowspan|colspan)\s*='

        # Schemaänderung dokumentieren
        $metadata.schema_version = "1.1"

        if ($hasMergedTableCells) {
            $prototypeStatus = "excluded"
            $tableStatus = "not suitable"
            $conversionStatus = "canceled"
            $excludedCount++

            $excludedArticles += [PSCustomObject]@{
                title       = $metadata.article.title
                revision_id = $metadata.article.revision_id
                html_file   = $htmlFileName
            }
        }
        else {
            $prototypeStatus = "included"
            $conversionStatus = "pending"

            # Die eigentliche Tabellenprüfung beziehungsweise
            # -verarbeitung findet erst im nächsten Schritt statt.
            $tableStatus = $null

            $includedCount++
        }

        # prototype_status ergänzen oder aktualisieren
        if ($metadata.PSObject.Properties.Name -contains "prototype_status") {
            $metadata.prototype_status = $prototypeStatus
        }
        else {
            $metadata | Add-Member `
                -MemberType NoteProperty `
                -Name "prototype_status" `
                -Value $prototypeStatus
        }

        # Bisherige Felder entfernen
        $metadata.conversion.PSObject.Properties.Remove("removed_tables")
        $metadata.conversion.PSObject.Properties.Remove("removed_images")

        # Neues Feld "tables" ergänzen oder aktualisieren
        if ($metadata.conversion.PSObject.Properties.Name -contains "tables") {
            $metadata.conversion.tables = $tableStatus
        }
        else {
            $metadata.conversion | Add-Member `
                -MemberType NoteProperty `
                -Name "tables" `
                -Value $tableStatus
        }

        # Neues Feld "images" ergänzen.
        # Die Befüllung erfolgt erst im nächsten Verarbeitungsschritt.
        if ($metadata.conversion.PSObject.Properties.Name -contains "images") {
            $metadata.conversion.images = $null
        }
        else {
            $metadata.conversion | Add-Member `
                -MemberType NoteProperty `
                -Name "images" `
                -Value $null
        }

        

        # Die eigentliche Konvertierung wurde noch nicht durchgeführt.
        # Für die Artikel mit nicht geeigneten Tabellen wird das Feld conversion.status auf "canceled" gesetzt 
        $metadata.conversion.status = $conversionStatus

        $updatedJson = $metadata |
            ConvertTo-Json -Depth 20

        [System.IO.File]::WriteAllText(
            $metadataFile.FullName,
            $updatedJson + [Environment]::NewLine,
            $utf8WithoutBom
        )

        $processedCount++
    }
    catch {
        $errorCount++
        Write-Warning (
            "Metadatendatei konnte nicht verarbeitet werden: " +
            "$($metadataFile.Name) – $($_.Exception.Message)"
        )
    }
}

Write-Host ""
Write-Host "Auswertung der Metadatenaktualisierung"
Write-Host "--------------------------------------"
Write-Host "Gefundene Metadatendateien: $($metadataFiles.Count)"
Write-Host "Erfolgreich verarbeitet:    $processedCount"
Write-Host "Für Prototyp vorgesehen:    $includedCount"
Write-Host "Vom Prototyp ausgeschlossen: $excludedCount"
Write-Host "Fehler:                     $errorCount"

if ($excludedCount -ne $expectedExcludedCount) {
    Write-Warning (
        "Es wurden $excludedCount Artikel ausgeschlossen. " +
        "Erwartet wurden $expectedExcludedCount Artikel."
    )
}
else {
    Write-Host ""
    Write-Host "Die erwarteten 46 Artikel wurden ausgeschlossen."
}

if ($excludedArticles.Count -gt 0) {
    Write-Host ""
    Write-Host "Ausgeschlossene Artikel:"
    $excludedArticles |
        Sort-Object title |
        Format-Table title, revision_id, html_file -AutoSize
}

if ($errorCount -gt 0) {
    throw (
        "Bei $errorCount Metadatendatei(en) trat ein Fehler auf. " +
        "Die Sicherung befindet sich unter: $backupDirectory"
    )
}












