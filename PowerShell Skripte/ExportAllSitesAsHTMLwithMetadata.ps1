<#

Exportiert die angegebenen Namespaces der MediaWiki Instanz in jeweils eine XML-Datei und erstellt pro Artikel einen HTML Export inkl. Metadaten im JSON Format

#>

# Eingabe der Anmeldedaten für Wiki Export
$cred = Get-Credential
# Arbeitsverzeichnis angeben
$rootPath = "<Arbeitsverzeichnis>"
# API URL der MediaWiki Instanz, Hostname einfügen
$wikiUrl = "https://<MediaWiki URL>/Wiki/api.php"

# Zu erstellende XML Dateien je Namespace 
$xmlPaths = @(
    (Join-path $rootPath "raw\export\Wiki-namespace-0.xml")
    (Join-path $rootPath "raw\export\Wiki-namespace-3004.xml")
)

# Wiki Namepsaces für Export angeben 
Invoke-WebRequest -Uri ($wikiUrl + '?action=query&generator=allpages&gapnamespace=0&gaplimit=max&export=1&exportnowrap=1') -OutFile $xmlPaths[0] -Credential $cred
Invoke-WebRequest -Uri ($wikiUrl + '?action=query&generator=allpages&gapnamespace=3004&gaplimit=max&export=1&exportnowrap=1') -OutFile $xmlPaths[1] -Credential $cred

$htmlDirectory = Join-Path `
    -Path $rootPath `
    -ChildPath "raw\html"

$imageListDirectory = Join-Path `
    -Path $rootPath `
    -ChildPath "raw\images\image_listen"

$metadataDirectory = Join-Path `
    -Path $rootPath `
    -ChildPath "metadaten"

    
# Ausgabeverzeichnisse anlegen, sofern diese noch nicht vorhanden sind.
    <#
@(
    $htmlDirectory,
    $imageListDirectory,
    $metadataDirectory
) | ForEach-Object {
    New-Item `
        -ItemType Directory `
        -Path $_ `
        -Force |
        Out-Null
}
        
    #>


# Einheitliche UTF-8-Kodierung ohne Byte Order Mark.
$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

foreach ($xmlPath in $xmlPaths) {
    Write-Host "Verarbeite: $xmlPath"


# XML-Export laden.
[xml]$xml = Get-Content `
    -LiteralPath $xmlPath `
    -Raw `
    -Encoding UTF8

$pages = @($xml.mediawiki.page)

if ($pages.Count -eq 0) {
    throw "Im XML-Export wurden keine Wikiartikel gefunden."
}

Write-Host "Gefundene Wikiartikel: $($pages.Count)"

# Fehler werden gesammelt und am Ende in einer JSON-Datei gespeichert.
$errorEntries = [System.Collections.Generic.List[object]]::new()

$i = 0

foreach ($page in $pages) {
    $i++

    $title = [string]$page.title
    $pageId = $null
    $revisionId = $null

    try {
        $pageId = [long]$page.id
        $namespaceId = [int]$page.ns

        # Pro Artikel muss genau eine Revision vorhanden sein.
        $revisionNodes = @($page.revision)

        if ($revisionNodes.Count -ne 1) {
            throw "Für den Artikel wurden $($revisionNodes.Count) Revisionen gefunden. Erwartet wurde genau eine Revision."
        }

        $revisionNode = $revisionNodes[0]
        $revisionId = [long]$revisionNode.id
        $revisionTimestamp = [string]$revisionNode.timestamp

        Write-Host "[$i/$($pages.Count)] Exportiere '$title' – Revision $revisionId"

        # ------------------------------------------------------------
        # Gerendertes HTML der im XML angegebenen Revision abrufen
        # ------------------------------------------------------------

        $parseParams = @{
            action             = "parse"
            oldid              = $revisionId
            prop               = "text|images|revid"
            format             = "json"
            formatversion      = "2"
            disabletoc         = "1" #Entfernt Table of Content
            disablelimitreport = "1" #Lässt Informationen über Verarbeitungvorgang (z.B. Dauer) während Download weg 
        }

        $parseResult = Invoke-RestMethod `
            -Uri $wikiUrl `
            -Method Get `
            -Body $parseParams `
            -Credential $cred `
            -ErrorAction Stop

        if ($null -ne $parseResult.error) {
            throw "Fehler der Parse-API: $($parseResult.error.code) – $($parseResult.error.info)"
        }

        if (
            $null -eq $parseResult.parse -or
            $null -eq $parseResult.parse.text
        ) {
            throw "Die Parse-API hat keinen HTML-Inhalt zurückgegeben."
        }

        $returnedRevisionId = [long]$parseResult.parse.revid

        if ($returnedRevisionId -ne $revisionId) {
            throw "Die angeforderte Revision $revisionId stimmt nicht mit der zurückgegebenen Revision $returnedRevisionId überein."
        }

        # ------------------------------------------------------------
        # Vollständige URL des Artikels abrufen
        # ------------------------------------------------------------

        $infoParams = @{
            action        = "query"
            pageids       = $pageId
            prop          = "info"
            inprop        = "url"
            format        = "json"
            formatversion = "2"
        }

        $infoResult = Invoke-RestMethod `
            -Uri $wikiUrl `
            -Method Get `
            -Body $infoParams `
            -Credential $cred `
            -ErrorAction Stop

        if ($null -ne $infoResult.error) {
            throw "Fehler der Info-API: $($infoResult.error.code) – $($infoResult.error.info)"
        }

        $pageInfo = @($infoResult.query.pages)[0]

        if ($null -eq $pageInfo) {
            throw "Für die Seiten-ID $pageId wurden keine Seiteninformationen zurückgegeben."
        }

        $articleUrl = [string]$pageInfo.fullurl

        if ([string]::IsNullOrWhiteSpace($articleUrl)) {
            throw "Für die Seiten-ID $pageId konnte keine vollständige Artikel-URL ermittelt werden."
        }

        # URL der konkret exportierten Revision erzeugen.
        $urlSeparator = if ($articleUrl.Contains("?")) {
            "&"
        }
        else {
            "?"
        }

        $revisionUrl = "${articleUrl}${urlSeparator}oldid=${revisionId}"

        # ------------------------------------------------------------
        # Dateinamen und Pfade festlegen
        # ------------------------------------------------------------

        $htmlFileName = "$revisionId.html"
        $markdownFileName = "$revisionId.md"
        $imageListFileName = "${revisionId}_imagelist.txt"
        $metadataFileName = "$revisionId.json"

        $htmlPath = Join-Path `
            -Path $htmlDirectory `
            -ChildPath $htmlFileName

        $imageListPath = Join-Path `
            -Path $imageListDirectory `
            -ChildPath $imageListFileName

        $metadataPath = Join-Path `
            -Path $metadataDirectory `
            -ChildPath $metadataFileName

        # ------------------------------------------------------------
        # HTML-Datei speichern
        # ------------------------------------------------------------

        $htmlContent = [string]$parseResult.parse.text

        [System.IO.File]::WriteAllText(
            $htmlPath,
            $htmlContent,
            $utf8WithoutBom
        )

        # ------------------------------------------------------------
        # Liste der referenzierten Bilder speichern
        # ------------------------------------------------------------

        $imageNames = @(
            $parseResult.parse.images |
                ForEach-Object {
                    [string]$_
                }
        )

        [System.IO.File]::WriteAllText(
            $imageListPath,
            ($imageNames -join [Environment]::NewLine),
            $utf8WithoutBom
        )

        # ------------------------------------------------------------
        # Prüfsumme der HTML-Datei erzeugen
        # ------------------------------------------------------------

        $htmlSha256 = (
            Get-FileHash `
                -LiteralPath $htmlPath `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        # ------------------------------------------------------------
        # Metadaten zusammenstellen
        # ------------------------------------------------------------

        $metadata = [ordered]@{
            schema_version = "1.0"

            article = [ordered]@{
                title                 = $title
                page_id               = $pageId
                namespace_id          = $namespaceId
                revision_id           = $revisionId
                revision_timestamp    = $revisionTimestamp
                article_url           = $articleUrl
                exported_revision_url = $revisionUrl
            }

            source = [ordered]@{
                api_url         = [string]$wikiUrl
                xml_export_file = Split-Path `
                    -Path $xmlPath `
                    -Leaf
            }

            files = [ordered]@{
                html_file              = $htmlFileName
                expected_markdown_file = $markdownFileName
                image_list_file        = $imageListFileName
            }

            export = [ordered]@{
                exported_at_utc        = [DateTimeOffset]::UtcNow.ToString("o")
                html_sha256            = $htmlSha256
                referenced_image_count = $imageNames.Count
            }

            # Diese Angaben werden erst bei der späteren
            # HTML-zu-Markdown-Konvertierung ergänzt.
            conversion = [ordered]@{
                status            = "pending"
                converter         = "MarkItDown"
                converter_version = $null
                converted_at_utc   = $null
                removed_tables    = $null
                removed_images    = $null
            }
        }

        $metadataJson = $metadata |
            ConvertTo-Json -Depth 8

        [System.IO.File]::WriteAllText(
            $metadataPath,
            $metadataJson,
            $utf8WithoutBom
        )

        Write-Host "Export erfolgreich: $htmlFileName"
    }
    catch {
        $errorMessage = $_.Exception.Message

        Write-Warning "Fehler beim Export von '$title', Revision ${revisionId}: $errorMessage"

        $errorEntries.Add(
            [pscustomobject]@{
                article_title = $title
                page_id       = $pageId
                revision_id   = $revisionId
                error         = $errorMessage
            }
        )
    }

    # API-Anfragen begrenzen.
    Start-Sleep -Seconds 1
}

# ------------------------------------------------------------
# Fehlerprotokoll schreiben
# ------------------------------------------------------------

$errorLogPath = Join-Path `
    -Path $metadataDirectory `
    -ChildPath "export_fehler.json"

$errorJson = ConvertTo-Json `
    -InputObject @($errorEntries) `
    -Depth 5

[System.IO.File]::WriteAllText(
    $errorLogPath,
    $errorJson,
    $utf8WithoutBom
)

if ($errorEntries.Count -gt 0) {
    Write-Warning "$($errorEntries.Count) Artikel konnten nicht vollständig exportiert werden. Siehe: $errorLogPath"
}
else {
    Write-Host "Alle $($pages.Count) Artikel wurden erfolgreich exportiert."
}
}