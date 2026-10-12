
<#
Erstellt eine neue Metadaten Datei pro Artikel mit den relevanten Aspekten für den Import nach Open WebUI

#>

# ARbeitsverzeichnis angeben
$rootPath = "<Arbeitsverzeichnis>"
$MetadataDirectory = "$rootPath\metadaten"

# StrictMode macht fehlende Eigenschaften und andere Programmfehler sichtbar.
# Fehler werden im try/catch-Block je Datei behandelt.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Prüfen, ob das benötigte Eingabeverzeichnis existiert.
if (-not (Test-Path -LiteralPath $MetadataDirectory -PathType Container)) {
    throw "Das Metadatenverzeichnis wurde nicht gefunden: $MetadataDirectory"
}

# JSON-Dateien sammeln. @() stellt auch bei nur einer Datei eine Liste bereit.
# Unterverzeichnisse werden nicht durchsucht.
$metadataFiles = @(Get-ChildItem `
    -LiteralPath $MetadataDirectory `
    -Filter "*.json" `
    -File)

if ($metadataFiles.Count -eq 0) {
    throw "Im Metadatenverzeichnis wurden keine JSON-Dateien gefunden."
}

# Für jeden Durchlauf einen neuen Ausgabeordner erstellen.
# Dadurch bleiben die Originale und frühere Ergebnisse unverändert.
# Der neue Ordner enthält nur die in diesem Durchlauf ausgewählten Metadaten.
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputDirectory = Join-Path `
    -Path $rootPath `
    -ChildPath "metadaten_upload_$timestamp"

New-Item `
    -Path $OutputDirectory `
    -ItemType Directory | Out-Null

Write-Host "Ausgabeordner erstellt:"
Write-Host $OutputDirectory
Write-Host ""

# Die erzeugten JSON-Dateien als UTF-8 ohne BOM speichern.
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

# Zähler für die abschließende Auswertung vorbereiten.
$processedCount = 0
$skippedCount = 0
$errorCount = 0

foreach ($metadataFile in $metadataFiles) {
    try {
        # JSON-Metadaten einlesen und in ein PowerShell-Objekt umwandeln.
        $jsonContent = [System.IO.File]::ReadAllText(
            $metadataFile.FullName,
            [System.Text.Encoding]::UTF8
        )

        $metadata = $jsonContent | ConvertFrom-Json

        if ($null -eq $metadata) {
            throw "Die JSON-Datei enthält kein Metadatenobjekt."
        }

        # Nur eingeschlossene und vollständig konvertierte Artikel übernehmen.
        # Fehlende Statusfelder führen ebenfalls zum Überspringen der Datei.
        # -cne vergleicht die Werte unter Beachtung der Groß-/Kleinschreibung.
        if (
            ($metadata.PSObject.Properties.Name -notcontains "prototype_status") -or
            ($metadata.PSObject.Properties.Name -notcontains "conversion") -or
            ($null -eq $metadata.conversion) -or
            ($metadata.conversion.PSObject.Properties.Name -notcontains "status") -or
            ($metadata.prototype_status -cne "included") -or
            ($metadata.conversion.status -cne "completed")
        ) {
            $skippedCount++
            continue
        }

        # Prüfen, ob das Artikelobjekt und die vier benötigten Werte vorhanden sind.
        if ($null -eq $metadata.article) {
            throw "Das Objekt 'article' fehlt."
        }

        foreach ($fieldName in @("title", "exported_revision_url", "revision_id", "revision_timestamp")) {
            if (
                ($metadata.article.PSObject.Properties.Name -notcontains $fieldName) -or
                [string]::IsNullOrWhiteSpace([string]$metadata.article.$fieldName)
            ) {
                throw "Das Feld 'article.$fieldName' fehlt oder ist leer."
            }
        }

      # Zeitstempel einheitlich als TT-MM-JJJJ (UTC-Datum) ausgeben.
        # PowerShell 7 liefert über ConvertFrom-Json ein DateTime-Objekt,
        # Windows PowerShell 5.1 liefert dagegen einen String.
        $revisionTimestamp = $metadata.article.revision_timestamp

        if ($revisionTimestamp -is [datetime]) {
            # PS 7 kann den Wert je nach Version in lokale Zeit umrechnen -> zurück nach UTC
            if ($revisionTimestamp.Kind -eq [System.DateTimeKind]::Local) {
                $revisionTimestamp = $revisionTimestamp.ToUniversalTime()
            }
        }
        else {
            $revisionTimestamp = [datetime]::Parse(
                [string]$revisionTimestamp,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }

        $revisionTimestamp = $revisionTimestamp.ToString(
            'dd-MM-yyyy',
            [System.Globalization.CultureInfo]::InvariantCulture
        )

        # Neues, flaches Metadatenformat aufbauen.
        # source_url verweist wie im Zielbeispiel auf die exportierte Revision.
        # [ordered] erhält die Reihenfolge der vier Felder.
        $uploadMetadata = [ordered]@{
            title              = $metadata.article.title
            source_url         = $metadata.article.exported_revision_url
            revision_id        = $metadata.article.revision_id
            revision_timestamp = $revisionTimestamp
        }

        # Aus 13122.json wird 13122.metadata.json.
        $outputFileName = $metadataFile.BaseName + ".metadata.json"
        $outputFilePath = Join-Path -Path $OutputDirectory -ChildPath $outputFileName

        # Das neue Objekt in JSON umwandeln und in den Ausgabeordner schreiben.
        $updatedJson = $uploadMetadata | ConvertTo-Json -Depth 5

        [System.IO.File]::WriteAllText(
            $outputFilePath,
            $updatedJson + [Environment]::NewLine,
            $utf8WithoutBom
        )

        $processedCount++
    }
    catch {
        # Fehler protokollieren und anschließend mit der nächsten Datei fortfahren.
        $errorCount++
        Write-Warning (
            "Metadatendatei konnte nicht verarbeitet werden: " +
            "$($metadataFile.Name) - $($_.Exception.Message)"
        )
    }
}

# Ergebnisse des Durchlaufs zusammenfassen.
Write-Host ""
Write-Host "Auswertung der Metadatenkonvertierung"
Write-Host "------------------------------------"
Write-Host "Gefundene Metadatendateien: $($metadataFiles.Count)"
Write-Host "Erfolgreich konvertiert:    $processedCount"
Write-Host "Uebersprungen:             $skippedCount"
Write-Host "Fehler:                    $errorCount"
Write-Host "Ausgabeordner:             $OutputDirectory"

# Falls einzelne Dateien fehlerhaft waren, den Durchlauf als fehlerhaft melden.
# Bereits erfolgreich erzeugte Dateien bleiben im Ausgabeordner erhalten.
if ($errorCount -gt 0) {
    throw "Bei $errorCount Metadatendatei(en) trat ein Fehler auf. Siehe die Warnungen oben."
}
