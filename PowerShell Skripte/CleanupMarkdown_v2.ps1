<#

Entfernt die Bearbeitungslinks (Buttons) in den Artikeln 
Macht aus relativen URLs absolute, damit die URLs klickbar sind und auf die MediaWiki Instanz verweisen
Parameter müssen bei Skriptaufruf übergeben werden

#>

param (
    [Parameter(Mandatory = $true)]
    [string]$MarkdownDirectory,

    # Basisadresse des Wikis. Relative Links der Form ](/Wiki/... werden
    # in absolute Links der Form ](https://<BaseURL>/Wiki/... umgewandelt.
    [string]$BaseUrl,

    # Mit -Preview werden nur die gefundenen Änderungen angezeigt.
    [switch]$Preview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $MarkdownDirectory -PathType Container)) {
    throw "Das Markdown-Verzeichnis wurde nicht gefunden: $MarkdownDirectory"
}

# Abschließenden Schrägstrich entfernen, damit keine doppelten "//" entstehen.
$BaseUrl = $BaseUrl.TrimEnd("/")

# @() stellt auch bei einer einzigen Datei eine Liste bereit.
$markdownFiles = @(Get-ChildItem `
    -LiteralPath $MarkdownDirectory `
    -Filter "*.md" `
    -File |
    Sort-Object Name)

if ($markdownFiles.Count -eq 0) {
    throw "Im angegebenen Verzeichnis wurden keine Markdown-Dateien gefunden."
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$backupDirectory = Join-Path `
    -Path (Split-Path $MarkdownDirectory -Parent) `
    -ChildPath "markdown_backup_cleanup_$timestamp"

$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

# Muster für relative Wiki-URLs direkt nach "](".
# Erfasst Bildquellen und Linkziele, Alternativtexte und Titel bleiben unverändert.
$relativeUrlPattern = '\]\(/Wiki/'
$absoluteUrlReplacement = "]($BaseUrl/Wiki/"

$processedFiles = 0
$modifiedFiles = 0
$removedEditBlocks = 0
$convertedUrls = 0
$errorCount = 0
$backupCreated = $false

foreach ($markdownFile in $markdownFiles) {
    try {
        $content = [System.IO.File]::ReadAllText(
            $markdownFile.FullName,
            [System.Text.Encoding]::UTF8
        )

        # Vorhandene Art des Zeilenumbruchs möglichst beibehalten
        if ($content.Contains("`r`n")) {
            $lineBreak = "`r`n"
        }
        else {
            $lineBreak = "`n"
        }

        $lines = [regex]::Split(
            $content,
            "\r\n|\n|\r"
        )

        $removedInCurrentFile = 0

        # Schritt 1: MediaWiki-Bearbeitungslinks aus Überschriften entfernen
        for ($lineNumber = 0; $lineNumber -lt $lines.Count; $lineNumber++) {
            $line = $lines[$lineNumber]
            $trimmedLine = $line.TrimStart()

            # Nur Markdown-Überschriften berücksichtigen.
            # Erfasst beispielsweise:
            # ## Überschrift
            # \## Überschrift
            if ($trimmedLine -notmatch '^\\?#{1,6}(?:\s|$)') {
                continue
            }

            # Die Zeile muss einen MediaWiki-Bearbeitungsaufruf enthalten.
            if ($line -notmatch '(?i)(?:veaction|action)=edit') {
                continue
            }

            $urlIndex = $line.IndexOf(
                "index.php?",
                [System.StringComparison]::OrdinalIgnoreCase
            )

            if ($urlIndex -lt 0) {
                continue
            }

            # Das letzte Vorkommen von "Bearbeiten" vor dem ersten
            # MediaWiki-Link bestimmen. Dadurch werden Überschriften,
            # die selbst das Wort "Bearbeiten" enthalten, nicht beschädigt.
            $textBeforeUrl = $line.Substring(0, $urlIndex)

            $editLabelIndex = $textBeforeUrl.LastIndexOf(
                "Bearbeiten",
                [System.StringComparison]::OrdinalIgnoreCase
            )

            if ($editLabelIndex -lt 0) {
                continue
            }

            # Die unmittelbar vor "Bearbeiten" stehenden öffnenden
            # Klammern und eventuellen Maskierungszeichen bestimmen.
            #
            # Unterstützte Beispiele:
            # [[Bearbeiten]
            # \[[Bearbeiten]
            # [\[Bearbeiten]
            # [Bearbeiten]
            $textBeforeEditLabel = $line.Substring(0, $editLabelIndex)

            $editBlockStart = [regex]::Match(
                $textBeforeEditLabel,
                '(?:\\?\[)+$'
            )

            if (-not $editBlockStart.Success) {
                continue
            }

            # Alles ab dem Bearbeitungsblock entfernen.
            # Die eigentliche Überschrift bleibt erhalten.
            $cleanedLine = $line.Substring(
                0,
                $editBlockStart.Index
            ).TrimEnd()

            if ($cleanedLine -ne $line) {
                $lines[$lineNumber] = $cleanedLine
                $removedInCurrentFile++
                $removedEditBlocks++
            }
        }

        $cleanedContent = $lines -join $lineBreak

        # Schritt 2: Relative Wiki-URLs in absolute URLs umwandeln.
        # Läuft nach Schritt 1, damit entfernte Bearbeitungslinks nicht
        # unnötig umgeschrieben werden.
        $convertedInCurrentFile = [regex]::Matches(
            $cleanedContent,
            $relativeUrlPattern
        ).Count

        if ($convertedInCurrentFile -gt 0) {
            $cleanedContent = [regex]::Replace(
                $cleanedContent,
                $relativeUrlPattern,
                $absoluteUrlReplacement
            )
            $convertedUrls += $convertedInCurrentFile
        }

        if ($removedInCurrentFile -gt 0 -or $convertedInCurrentFile -gt 0) {
            if ($Preview) {
                Write-Host (
                    "[Vorschau] {0}: {1} Bearbeitungslink(s), {2} relative URL(s)" -f
                    $markdownFile.Name,
                    $removedInCurrentFile,
                    $convertedInCurrentFile
                )
            }
            else {
                # Sicherungsverzeichnis erst bei der ersten Änderung anlegen
                if (-not $backupCreated) {
                    New-Item `
                        -Path $backupDirectory `
                        -ItemType Directory `
                        -Force | Out-Null

                    $backupCreated = $true
                }

                Copy-Item `
                    -LiteralPath $markdownFile.FullName `
                    -Destination $backupDirectory `
                    -Force

                [System.IO.File]::WriteAllText(
                    $markdownFile.FullName,
                    $cleanedContent,
                    $utf8WithoutBom
                )

                Write-Host (
                    "{0}: {1} Bearbeitungslink(s) entfernt, {2} relative URL(s) umgewandelt" -f
                    $markdownFile.Name,
                    $removedInCurrentFile,
                    $convertedInCurrentFile
                )
            }

            $modifiedFiles++
        }

        $processedFiles++
    }
    catch {
        $errorCount++

        Write-Warning (
            "Fehler beim Verarbeiten von {0}: {1}" -f
            $markdownFile.Name,
            $_.Exception.Message
        )
    }
}

Write-Host ""
Write-Host "Ergebnis der Bereinigung"
Write-Host "------------------------"
Write-Host "Markdown-Dateien insgesamt:   $($markdownFiles.Count)"
Write-Host "Erfolgreich geprüft:          $processedFiles"
Write-Host "Betroffene Dateien:           $modifiedFiles"
Write-Host "Entfernte Bearbeitungslinks:  $removedEditBlocks"
Write-Host "Umgewandelte relative URLs:   $convertedUrls"
Write-Host "Fehler:                       $errorCount"

if ($Preview) {
    Write-Host ""
    Write-Host "Es wurden keine Dateien verändert, da -Preview verwendet wurde."
}
elseif ($backupCreated) {
    Write-Host ""
    Write-Host "Sicherung der veränderten Originaldateien:"
    Write-Host $backupDirectory
}
else {
    Write-Host ""
    Write-Host "Es wurden keine Bearbeitungslinks oder relativen URLs gefunden."
}
