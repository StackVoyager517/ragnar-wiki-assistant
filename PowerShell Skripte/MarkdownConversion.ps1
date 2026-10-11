<# 

Konvertiert die zuvor exportieren HTML Dateien in ein Markdown Format
Setzt Metadaten
Parameter müssen bei Skriptaufruf übergeben werden

#>

param (
    [Parameter(Mandatory = $true)]
    [string]$MetadataDirectory,

    [Parameter(Mandatory = $true)]
    [string]$HtmlDirectory,

    [Parameter(Mandatory = $true)]
    [string]$MarkdownDirectory,

    [string]$MarkItDownCommand = "markitdown.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Set-JsonProperty {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        $Object | Add-Member `
            -MemberType NoteProperty `
            -Name $Name `
            -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

# Verzeichnisse prüfen
if (-not (Test-Path -LiteralPath $MetadataDirectory -PathType Container)) {
    throw "Das Metadatenverzeichnis wurde nicht gefunden: $MetadataDirectory"
}

if (-not (Test-Path -LiteralPath $HtmlDirectory -PathType Container)) {
    throw "Das HTML-Verzeichnis wurde nicht gefunden: $HtmlDirectory"
}

if (-not (Test-Path -LiteralPath $MarkdownDirectory -PathType Container)) {
    New-Item `
        -Path $MarkdownDirectory `
        -ItemType Directory `
        -Force | Out-Null
}

# MarkItDown suchen
$markItDownApplication = Get-Command `
    -Name $MarkItDownCommand `
    -ErrorAction Stop

$markItDownExecutable = $markItDownApplication.Source

Write-Host "Verwendete MarkItDown-Anwendung:"
Write-Host $markItDownExecutable
Write-Host ""

# Installierte MarkItDown-Version
$converterVersion = "0.1.8"


# Sicherungsverzeichnisse erstellen
$runTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$metadataBackupDirectory = Join-Path `
    -Path (Split-Path $MetadataDirectory -Parent) `
    -ChildPath "metadaten_backup_conversion_$runTimestamp"

$markdownBackupDirectory = Join-Path `
    -Path $MarkdownDirectory `
    -ChildPath "_backup_$runTimestamp"

New-Item `
    -Path $metadataBackupDirectory `
    -ItemType Directory `
    -Force | Out-Null

# Alle Metadaten vor der Bearbeitung sichern
Get-ChildItem `
    -LiteralPath $MetadataDirectory `
    -Filter "*.json" `
    -File |
    Copy-Item `
        -Destination $metadataBackupDirectory `
        -Force

# UTF-8 ohne BOM
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

$metadataFiles = Get-ChildItem `
    -LiteralPath $MetadataDirectory `
    -Filter "*.json" `
    -File |
    Sort-Object Name

$totalCount = $metadataFiles.Count
$pendingCount = 0
$completedCount = 0
$skippedCount = 0
$failedCount = 0

foreach ($metadataFile in $metadataFiles) {
    $temporaryMarkdownPath = $null
    $commandOutput = $null

    try {
        $jsonContent = [System.IO.File]::ReadAllText(
            $metadataFile.FullName,
            [System.Text.Encoding]::UTF8
        )

        $metadata = $jsonContent | ConvertFrom-Json

        if ($null -eq $metadata.conversion) {
            throw "Das Objekt 'conversion' fehlt."
        }

        $conversionStatus = [string]$metadata.conversion.status

        # Nur Artikel mit Status "pending" konvertieren
        if ($conversionStatus -ne "pending") {
            $skippedCount++
            continue
        }

        $pendingCount++

        $htmlFileName = [string]$metadata.files.html_file
        $markdownFileName = [string]$metadata.files.expected_markdown_file

        if ([string]::IsNullOrWhiteSpace($htmlFileName)) {
            throw "Im Feld 'files.html_file' fehlt der Dateiname."
        }

        if ([string]::IsNullOrWhiteSpace($markdownFileName)) {
            throw "Im Feld 'files.expected_markdown_file' fehlt der Dateiname."
        }

        $htmlFilePath = Join-Path `
            -Path $HtmlDirectory `
            -ChildPath $htmlFileName

        $markdownFilePath = Join-Path `
            -Path $MarkdownDirectory `
            -ChildPath $markdownFileName

        if (-not (Test-Path -LiteralPath $htmlFilePath -PathType Leaf)) {
            throw "Die HTML-Datei wurde nicht gefunden: $htmlFilePath"
        }

        # Prüfen, ob die HTML-Datei seit dem Export verändert wurde
        if (
            $null -ne $metadata.export -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$metadata.export.html_sha256
            )
        ) {
            $expectedHtmlHash = (
                [string]$metadata.export.html_sha256
            ).ToLowerInvariant()

            $currentHtmlHash = (
                Get-FileHash `
                    -LiteralPath $htmlFilePath `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()

            if ($currentHtmlHash -ne $expectedHtmlHash) {
                throw (
                    "Der SHA-256-Hash der HTML-Datei stimmt nicht mit " +
                    "dem in den Metadaten gespeicherten Hash überein."
                )
            }
        }

        # Zunächst in eine temporäre Datei schreiben
        $markdownBaseName = [System.IO.Path]::GetFileNameWithoutExtension(
            $markdownFileName
        )

        $temporaryMarkdownPath = Join-Path `
            -Path $MarkdownDirectory `
            -ChildPath "$markdownBaseName.tmp.md"

        if (Test-Path -LiteralPath $temporaryMarkdownPath) {
            Remove-Item `
                -LiteralPath $temporaryMarkdownPath `
                -Force
        }

        Write-Host (
            "Konvertiere: {0} -> {1}" -f
            $htmlFileName,
            $markdownFileName
        )

        $commandOutput = & $markItDownExecutable `
            $htmlFilePath `
            -o $temporaryMarkdownPath `
            2>&1

        $markItDownExitCode = $LASTEXITCODE

        if ($markItDownExitCode -ne 0) {
            throw (
                "MarkItDown wurde mit Exitcode " +
                "$markItDownExitCode beendet. " +
                (($commandOutput | Out-String).Trim())
            )
        }

        if (-not (Test-Path -LiteralPath $temporaryMarkdownPath -PathType Leaf)) {
            throw "MarkItDown hat keine Ausgabedatei erzeugt."
        }

        $temporaryMarkdownFile = Get-Item `
            -LiteralPath $temporaryMarkdownPath

        if ($temporaryMarkdownFile.Length -eq 0) {
            throw "Die erzeugte Markdown-Datei ist leer."
        }

        # Bereits vorhandene Markdown-Datei sichern
        if (Test-Path -LiteralPath $markdownFilePath -PathType Leaf) {
            if (-not (Test-Path -LiteralPath $markdownBackupDirectory)) {
                New-Item `
                    -Path $markdownBackupDirectory `
                    -ItemType Directory `
                    -Force | Out-Null
            }

            Copy-Item `
                -LiteralPath $markdownFilePath `
                -Destination $markdownBackupDirectory `
                -Force

            Remove-Item `
                -LiteralPath $markdownFilePath `
                -Force
        }

        # Temporäre Datei als endgültige Markdown-Datei übernehmen
        Move-Item `
            -LiteralPath $temporaryMarkdownPath `
            -Destination $markdownFilePath `
            -Force

        # Metadaten nach erfolgreicher Konvertierung aktualisieren
        Set-JsonProperty `
            -Object $metadata.conversion `
            -Name "status" `
            -Value "completed"

        Set-JsonProperty `
            -Object $metadata.conversion `
            -Name "converter" `
            -Value "MarkItDown"

        Set-JsonProperty `
            -Object $metadata.conversion `
            -Name "converter_version" `
            -Value $converterVersion

        Set-JsonProperty `
            -Object $metadata.conversion `
            -Name "converted_at_utc" `
            -Value ([DateTime]::UtcNow.ToString("o"))

        $updatedJson = $metadata | ConvertTo-Json -Depth 20

        # Aktualisierte Metadaten zunächst temporär speichern
        $temporaryMetadataPath = $metadataFile.FullName + ".tmp"

        [System.IO.File]::WriteAllText(
            $temporaryMetadataPath,
            $updatedJson + [Environment]::NewLine,
            $utf8WithoutBom
        )

        Move-Item `
            -LiteralPath $temporaryMetadataPath `
            -Destination $metadataFile.FullName `
            -Force

        $completedCount++
    }
    catch {
        $failedCount++

        if (
            $null -ne $temporaryMarkdownPath -and
            (Test-Path -LiteralPath $temporaryMarkdownPath)
        ) {
            Remove-Item `
                -LiteralPath $temporaryMarkdownPath `
                -Force
        }

        Write-Warning (
            "Konvertierung fehlgeschlagen für " +
            "$($metadataFile.Name): $($_.Exception.Message)"
        )

        # Der Status bleibt bei einem Fehler auf "pending",
        # damit die Konvertierung später erneut ausgeführt werden kann.
    }
}

Write-Host ""
Write-Host "Ergebnis der Markdown-Konvertierung"
Write-Host "-----------------------------------"
Write-Host "Metadatendateien insgesamt: $totalCount"
Write-Host "Status pending gefunden:    $pendingCount"
Write-Host "Erfolgreich konvertiert:    $completedCount"
Write-Host "Nicht zu verarbeiten:       $skippedCount"
Write-Host "Fehlgeschlagen:             $failedCount"
Write-Host ""
Write-Host "Sicherung der Metadaten:"
Write-Host $metadataBackupDirectory

if (Test-Path -LiteralPath $markdownBackupDirectory) {
    Write-Host ""
    Write-Host "Sicherung bereits vorhandener Markdown-Dateien:"
    Write-Host $markdownBackupDirectory
}

if ($failedCount -gt 0) {
    Write-Warning (
        "$failedCount Konvertierung(en) sind fehlgeschlagen. " +
        "Die zugehörigen Metadaten behalten den Status 'pending'."
    )
}