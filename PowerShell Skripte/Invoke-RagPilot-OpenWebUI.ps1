<#
.SYNOPSIS
  Führt Referenzkarten gegen Open WebUI aus und archiviert Antwort, Quellen und
  von Open WebUI im Chat-Export bereitgestellte Retrieval-Abschnitte.

.BASIS
  Dieser Ablauf ist an die HAR-Aufzeichnung vom 13.10.2026 angepasst:
  POST /api/chat/completions  -> { chat_id, task_ids }
  GET  /api/v1/chats/{chat_id} -> vollständiger Chat inklusive history.messages,
                                  sources und usage.

WICHTIG
  Die Datei retrieved_context_reported.json enthält die von Open WebUI im
  gespeicherten Chat als sources.document ausgewiesenen Abschnitte. Das ist ein
  dokumentierter Retrieval-Nachweis, aber kein endgültiger Beweis, dass exakt
  nur diese Abschnitte in derselben Form im finalen Modellprompt standen.
  Das Feld retrieved_context_verified wird daher bewusst auf false gesetzt.

  Das Skript ist für einen nicht-streamenden Batch-Lauf gedacht. Jede Karte wird
  als neuer, eigenständiger Chat gesendet.

AUSGABEARTEFAKTE JE TESTFALL
  reference_card.json              unveränderte verwendete Referenzkarte
  request.json                     tatsächlich gesendete Open-WebUI-Anfrage
  submit_response.json             direkte Antwort der POST-Anfrage mit chat_id
  chat_export_latest.json          zuletzt abgerufener Zwischenstand des Chats
  chat_export_final.json           endgültiger exportierter Chat nach Abschluss
  answer.txt                       daraus extrahierte Originalantwort
  sources_reported_raw.json        unverändert von Open WebUI gespeicherte Quellenstruktur
  retrieved_context_reported.json  pro Chunk normalisierte Quellen, Texte und Metadaten
  run_metadata.json                Laufstatus, Zeiten, Zähler und methodische Hinweise
  error.txt                        Ausnahmeinformationen bei einem technischen Fehler

MESSGRENZE
  Die Ende-zu-Ende-Zeit beginnt unmittelbar vor dem POST an Open WebUI und endet,
  sobald Open WebUI die zugehörige Assistant-Nachricht als done speichert. Die Zeit
  umfasst damit Anfrageverarbeitung, Retrieval, Promptaufbau, Modellinferenz und
  die in diesem Ablauf erforderlichen Abrufe des gespeicherten Chat-Status. Sie
  trennt Retrieval- und Generierungszeit nicht.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'pilot-openwebui-config.json'),

    [Parameter(Mandatory = $false)]
    [string]$RunLabel = ('CAL-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),

    [Parameter(Mandatory = $false)]
    [switch]$AllowUnapprovedCards,

    [Parameter(Mandatory = $false)]
    [switch]$SkipTlsCertificateCheck
)

# Strikte Variablen- und Fehlerbehandlung verhindern, dass fehlende Felder unbemerkt
# zu unvollständigen Protokolldaten führen. Fehler eines Testfalls werden trotzdem im
# try/catch abgelegt, damit die Ursache in error.txt nachvollziehbar bleibt.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Liest ein optionales JSON-/PSCustomObject-Feld sicher aus. Open WebUI kann einzelne
# Felder versions- oder laufabhängig weglassen; dann wird der definierte Standardwert genutzt.
function Get-PropertyValue {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

# Schreibt Textdateien immer als UTF-8 BOM. 
# Referenzkarten und JSON-Dateien konsistent und die Dateien sind plattformübergreifend lesbar.
function Write-Utf8Bom {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

# Zentraler JSON-Export mit hoher Objekttiefe. Die Open-WebUI-Chatstruktur ist verschachtelt;
# eine zu geringe ConvertTo-Json-Tiefe würde Teile der Quellen- oder Nutzungsdaten abschneiden.
function Write-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Object, [int]$Depth = 50)
    Write-Utf8Bom -Path $Path -Content ($Object | ConvertTo-Json -Depth $Depth)
}

# Bereinigt Lauf- und Testfallnamen für Windows-Dateipfade. Die fachliche Fragen-ID bleibt
# in den JSON-Artefakten unverändert; nur der Verzeichnisname wird angepasst.
function ConvertTo-SafePathPart {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[\\/:*?"<>|\s]+', '_')
}

# Open WebUI erwartet für user_message.timestamp einen Unix-Zeitstempel in Sekunden.
function ConvertTo-UnixTimestamp {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# Die POST-Antwort enthält nur die chat_id. Die eigentliche Antwort wird im späteren
# Chat-Export anhand der bereits vorab erzeugten Assistant-Nachrichten-ID gefunden.
function Get-MessageById {
    param([Parameter(Mandatory = $true)]$ChatEnvelope, [Parameter(Mandatory = $true)][string]$MessageId)
    $messages = Get-PropertyValue -Object $ChatEnvelope.chat.history -Name 'messages'
    return Get-PropertyValue -Object $messages -Name $MessageId
}

# Normalisiert die im gespeicherten Open-WebUI-Chat ausgewiesenen Retrieval-Abschnitte.
# Das Ergebnis dient als Rohmaterial für QA-01, QA-03 und eine spätere RAGChecker-Eingabe.
# Wichtig: Der Funktionsname enthält absichtlich "Reported". Das Artefakt zeigt von Open WebUI
# gespeicherte Quellenabschnitte, ist aber kein unabhängiger Beweis des finalen Modellprompts.
function Get-ReportedContexts {
    param([Parameter(Mandatory = $true)]$AssistantMessage)

    # Normales PowerShell-Array statt Generic List: vermeidet Typbindungsfehler in Windows PowerShell.
    $contexts = @()
    # sources ist in der beobachteten Open-WebUI-Struktur eine Liste von Quellengruppen,
    # z. B. eine Gruppe für die Collection Wiki_Wissensbestand_v2.
    $groups = @(Get-PropertyValue -Object $AssistantMessage -Name 'sources' -Default @())
    $rank = 0

    for ($groupIndex = 0; $groupIndex -lt $groups.Count; $groupIndex++) {
        $group = $groups[$groupIndex]
        $documents = @(Get-PropertyValue -Object $group -Name 'document' -Default @())
        $metadataList = @(Get-PropertyValue -Object $group -Name 'metadata' -Default @())
        $distances = @(Get-PropertyValue -Object $group -Name 'distances' -Default @())
        $sourceInfo = Get-PropertyValue -Object $group -Name 'source' -Default $null

        for ($i = 0; $i -lt $documents.Count; $i++) {
            $rank++
            $metadata = if ($i -lt $metadataList.Count) { $metadataList[$i] } else { $null }
            $name = Get-PropertyValue -Object $metadata -Name 'name' -Default 'unknown-document'
            $revisionId = Get-PropertyValue -Object $metadata -Name 'revision_id' -Default 'unknown-revision'
            $fileId = Get-PropertyValue -Object $metadata -Name 'file_id' -Default $null
            $distance = if ($i -lt $distances.Count) { $distances[$i] } else { $null }

            # Die Rangnummer ist Teil der ID, weil derselbe Artikel mehrere Chunks liefern kann.
            # Sie beschreibt die Reihenfolge im gespeicherten sources.document-Array, nicht
            # zwingend die genaue Reihenfolge im finalen Modellprompt.
            $docId = ('{0}#reported-rank-{1}' -f $name, $rank)
            $contexts += [pscustomobject]@{
                rank = $rank
                doc_id = $docId
                text = [string]$documents[$i]
                retrieval_distance = $distance
                collection_id = Get-PropertyValue -Object $sourceInfo -Name 'id'
                collection_name = Get-PropertyValue -Object $sourceInfo -Name 'name'
                source_file = $name
                file_id = $fileId
                article_title = Get-PropertyValue -Object $metadata -Name 'title'
                revision_id = $revisionId
                revision_timestamp = Get-PropertyValue -Object $metadata -Name 'revision_timestamp'
                source_url = Get-PropertyValue -Object $metadata -Name 'source_url'
                start_index = Get-PropertyValue -Object $metadata -Name 'start_index'
                group_index = $groupIndex + 1
                index_in_group = $i + 1
            }
        }
    }
    return $contexts
}

# Baut die HTTP-Header. Geheimnisse werden nur aus einer Umgebungsvariablen gelesen und
# niemals in request.json, run_metadata.json oder die Referenzkarten geschrieben.
function Get-HttpHeaders {
    param([Parameter(Mandatory = $true)]$Config)
    $headers = @{ 'Accept' = 'application/json' }
    $mode = Get-PropertyValue -Object $Config -Name 'authentication_mode' -Default 'none'

    if ($mode -eq 'bearer_environment_variable') {
        $environmentName = Get-PropertyValue -Object $Config -Name 'token_environment_variable'
        $token = [Environment]::GetEnvironmentVariable($environmentName)
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Die Umgebungsvariable $environmentName ist nicht gesetzt."
        }
        $headers['Authorization'] = "Bearer $token"
    }
    elseif ($mode -ne 'none') {
        throw "Nicht unterstützter authentication_mode: $mode"
    }
    return $headers
}

# --- Phase 1: Konfiguration laden und vor dem ersten Netzwerkzugriff validieren ---
# Dadurch schlägt eine unvollständige Konfiguration früh fehl, ohne Testfälle zu erzeugen.
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Konfigurationsdatei nicht gefunden: $ConfigPath" }
$configFullPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDirectory = Split-Path -Parent $configFullPath
$config = Get-Content -LiteralPath $configFullPath -Raw -Encoding UTF8 | ConvertFrom-Json

$baseUri = (Get-PropertyValue -Object $config -Name 'openwebui_base_uri').TrimEnd('/')
$model = Get-PropertyValue -Object $config -Name 'model'
$modelItem = Get-PropertyValue -Object $config -Name 'model_item'
$referenceCardsDirectory = Get-PropertyValue -Object $config -Name 'reference_cards_directory'
$outputDirectory = Get-PropertyValue -Object $config -Name 'output_directory'
$timeoutSeconds = [int](Get-PropertyValue -Object $config -Name 'timeout_seconds' -Default 300)
$pollIntervalMs = [int](Get-PropertyValue -Object $config -Name 'poll_interval_ms' -Default 1000)
$includeCardIds = @(Get-PropertyValue -Object $config -Name 'include_card_ids' -Default @())
$knowledgeBindingConfirmed = [bool](Get-PropertyValue -Object $config -Name 'knowledge_base_binding_confirmed' -Default $false)

if ([string]::IsNullOrWhiteSpace($baseUri)) { throw 'openwebui_base_uri fehlt.' }
if ([string]::IsNullOrWhiteSpace($model)) { throw 'model fehlt.' }
if ($null -eq $modelItem) { throw 'model_item fehlt.' }
# Schutz vor einem unbeabsichtigten Modelltest ohne den vorgesehenen RAG-Wissensbestand.
# Die Bestätigung bezieht sich auf die in der HAR-Datei nachgewiesene model_item.info.meta.knowledge-Struktur.
if (-not $knowledgeBindingConfirmed) { throw 'knowledge_base_binding_confirmed ist nicht true. Kein Lauf wird gestartet.' }

if (-not [System.IO.Path]::IsPathRooted($referenceCardsDirectory)) { $referenceCardsDirectory = Join-Path $configDirectory $referenceCardsDirectory }
if (-not [System.IO.Path]::IsPathRooted($outputDirectory)) { $outputDirectory = Join-Path $configDirectory $outputDirectory }
if (-not (Test-Path -LiteralPath $referenceCardsDirectory)) { throw "Referenzkartenordner nicht gefunden: $referenceCardsDirectory" }

# Optional nur für interne Testinstanzen mit selbstsigniertem Zertifikat. Im Normalbetrieb
# bleibt die TLS-Zertifikatsprüfung aktiv. Die Option ist keine fachliche Pilotkonfiguration.
if ($SkipTlsCertificateCheck) {
    if ($PSVersionTable.PSVersion.Major -ge 7) { $PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true }
    else {
        Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; } }
'@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
}

# --- Phase 2: Laufordner vorbereiten und verwendete Konfiguration archivieren ---
# Die Kopie der Konfiguration macht später nachvollziehbar, mit welcher API- und Modellbindung
# ein bestimmter Lauf durchgeführt wurde.
$headers = Get-HttpHeaders -Config $config
$runRoot = Join-Path $outputDirectory (ConvertTo-SafePathPart $RunLabel)
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
Copy-Item -LiteralPath $configFullPath -Destination (Join-Path $runRoot 'pilot-openwebui-config.used.json') -Force

$cards = @(Get-ChildItem -LiteralPath $referenceCardsDirectory -Filter '*.json' -File | Sort-Object Name)
if ($cards.Count -eq 0) { throw "Keine JSON-Referenzkarten in $referenceCardsDirectory gefunden." }

$records = New-Object System.Collections.Generic.List[object]

# --- Phase 3: Jede Referenzkarte als isolierten Testfall ausführen ---
# Ein Testfall erhält einen eigenen Chat. Damit beeinflussen vorherige Fragen oder Antworten
# den folgenden Lauf nicht über den Chat-Verlauf.
foreach ($cardFile in $cards) {
    $card = Get-Content -LiteralPath $cardFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $questionId = Get-PropertyValue -Object $card -Name 'fragen_id'
    $question = Get-PropertyValue -Object $card -Name 'fragestellung'
    $reviewStatus = Get-PropertyValue -Object $card -Name 'pruefstatus'

    if ([string]::IsNullOrWhiteSpace($questionId) -or [string]::IsNullOrWhiteSpace($question)) {
        throw "Ungültige Karte: $($cardFile.FullName)"
    }
    # include_card_ids erlaubt gezielte Probeläufe, z. B. nur K-01. Eine leere Liste bedeutet:
    # alle gefundenen Referenzkarten verarbeiten.
    if (($includeCardIds.Count -gt 0) -and ($includeCardIds -notcontains $questionId)) { continue }
    if ((@('selbst_geprueft', 'fachlich_geprueft') -notcontains $reviewStatus) -and (-not $AllowUnapprovedCards)) {
        Write-Warning "Überspringe ${questionId}: pruefstatus=$reviewStatus"
        continue
    }

    # Die unveränderte Referenzkarte wird neben den Rohdaten kopiert. Spätere Änderungen an
    # reference-cards wirken daher nicht rückwirkend auf bereits dokumentierte Läufe.
    $caseDirectory = Join-Path $runRoot (ConvertTo-SafePathPart $questionId)
    New-Item -ItemType Directory -Path $caseDirectory -Force | Out-Null
    Copy-Item -LiteralPath $cardFile.FullName -Destination (Join-Path $caseDirectory 'reference_card.json') -Force

    # Neue IDs erzwingen einen neuen Chat und vermeiden Kontexte vorheriger Testfälle.
    $userMessageId = [guid]::NewGuid().ToString()
    $assistantMessageId = [guid]::NewGuid().ToString()
    $sessionId = [guid]::NewGuid().ToString('N')

    # Die Payload bildet die in der HAR-Datei beobachtete Open-WebUI-Anfrage nach.
    # model_item enthält die fest gebundene Collection Wiki_Wissensbestand_v2. Die Frage selbst
    # wird unverändert aus fragestellung der Referenzkarte übernommen.
    $payload = [ordered]@{
        # Open WebUI antwortet bei stream=true zunächst asynchron mit chat_id und task_ids.
        # Die vollständige Antwort wird deshalb anschließend über /api/v1/chats/{chat_id} abgefragt.
        stream = $true
        model = $model
        params = @{ tool_approval_mode = 'full' }
        tool_servers = @()
        features = @{ voice = $false; image_generation = $false; code_interpreter = $false; web_search = $false; memory = $true }
        variables = @{}
        chat_variables = @{}
        model_item = $modelItem
        actions = @()
        filters = @()
        session_id = $sessionId
        id = $assistantMessageId
        message_ids = @(@{ model_id = $model; message_id = $assistantMessageId; modelIdx = 0 })
        parent_id = $null
        user_message = @{
            id = $userMessageId
            parentId = $null
            childrenIds = @($assistantMessageId)
            role = 'user'
            content = $question
            timestamp = (ConvertTo-UnixTimestamp)
            models = @($model)
        }
        # Nebenaufgaben werden deaktiviert, um Laufzeit und Chatdaten nicht durch automatische
        # Titel-, Tag- oder Follow-up-Generierung zu beeinflussen.
        background_tasks = @{ title_generation = $false; tags_generation = $false; follow_up_generation = $false }
    }

    $requestJson = $payload | ConvertTo-Json -Depth 60
    Write-Utf8Bom -Path (Join-Path $caseDirectory 'request.json') -Content $requestJson

    # --- Phase 4: Anfrage senden und den Abschluss des asynchronen Chats abwarten ---
    # Die Stoppuhr startet direkt vor dem Senden. Damit wird die vorab definierte Ende-zu-Ende-
    # Messgrenze technisch einheitlich auf alle Testfälle angewendet.
    $startUtc = [DateTime]::UtcNow
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'failed'
    $note = ''
    $httpStatus = $null
    $chatId = $null
    $answer = $null
    $assistantMessage = $null
    $contexts = @()

    try {
        Write-Host "Sende $questionId ..." -ForegroundColor Cyan
        # 1. POST startet die Open-WebUI-Verarbeitung. Die direkte Antwort enthält nach dem
        # beobachteten API-Ablauf noch nicht den Antworttext, sondern eine chat_id.
        $submit = Invoke-WebRequest -Uri "$baseUri/api/chat/completions" -Method POST -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $requestJson -TimeoutSec $timeoutSeconds -UseBasicParsing
        $httpStatus = [int]$submit.StatusCode
        Write-Utf8Bom -Path (Join-Path $caseDirectory 'submit_response.json') -Content $submit.Content
        $submitObject = $submit.Content | ConvertFrom-Json
        $chatId = Get-PropertyValue -Object $submitObject -Name 'chat_id'
        if ([string]::IsNullOrWhiteSpace($chatId)) { throw 'Die API-Antwort enthält keine chat_id.' }

        # 2. Polling: Der Chat wird in festen Intervallen abgerufen, bis die passende
        # Assistant-Nachricht done=true trägt oder das vorgegebene Zeitlimit erreicht ist.
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
        do {
            Start-Sleep -Milliseconds $pollIntervalMs
            $chatResponse = Invoke-WebRequest -Uri "$baseUri/api/v1/chats/$chatId" -Method GET -Headers $headers -TimeoutSec 30 -UseBasicParsing
            # Der letzte Zwischenstand bleibt ebenfalls erhalten. Das erleichtert die Analyse
            # von Abbrüchen, unvollständigen Antworten oder Timeout-Fällen.
            Write-Utf8Bom -Path (Join-Path $caseDirectory 'chat_export_latest.json') -Content $chatResponse.Content
            $chatEnvelope = $chatResponse.Content | ConvertFrom-Json
            $assistantMessage = Get-MessageById -ChatEnvelope $chatEnvelope -MessageId $assistantMessageId
            $isDone = [bool](Get-PropertyValue -Object $assistantMessage -Name 'done' -Default $false)
        } while ((-not $isDone) -and ([DateTime]::UtcNow -lt $deadline))

        if (-not $isDone) { throw "Zeitüberschreitung: Assistant-Nachricht $assistantMessageId wurde nicht als done gespeichert." }
        $stopwatch.Stop()
        $endUtc = [DateTime]::UtcNow

        # --- Phase 5: Vollständige Rohdaten und normalisierte Auswertungsartefakte sichern ---
        # Der finale Chat-Export bleibt unverändert die maßgebliche Rohquelle dieses Laufes.
        Write-JsonFile -Path (Join-Path $caseDirectory 'chat_export_final.json') -Object $chatEnvelope
        $answer = Get-PropertyValue -Object $assistantMessage -Name 'content'
        Write-Utf8Bom -Path (Join-Path $caseDirectory 'answer.txt') -Content ([string]$answer)

        # Zuerst wird die unveränderte sources-Struktur gespeichert. Danach wird daraus eine
        # flache, gut vergleichbare Liste einzelner Kontextabschnitte erzeugt.
        $rawSources = Get-PropertyValue -Object $assistantMessage -Name 'sources' -Default @()
        Write-JsonFile -Path (Join-Path $caseDirectory 'sources_reported_raw.json') -Object $rawSources
        $contexts = Get-ReportedContexts -AssistantMessage $assistantMessage
        Write-JsonFile -Path (Join-Path $caseDirectory 'retrieved_context_reported.json') -Object $contexts

        $status = 'completed'
    }
    catch {
        # Fehler werden nicht verdeckt wiederholt. Der Fehlzustand, die bereits vorhandenen
        # Rohdateien und die Fehlerbeschreibung bleiben als technisches Ergebnis erhalten.
        $stopwatch.Stop()
        $endUtc = [DateTime]::UtcNow
        $note = $_.Exception.Message
        Write-Utf8Bom -Path (Join-Path $caseDirectory 'error.txt') -Content ($_ | Out-String)
        Write-Warning "$questionId fehlgeschlagen: $note"
    }

    # --- Phase 6: Laufmetadaten und tabellarisches Gesamtprotokoll erzeugen ---
    # Die Anzahl der Quellengruppen und Kontextabschnitte ist ein technischer Beobachtungswert.
    # Sie belegt weder Vollständigkeit der Quellen noch eine tatsächliche Zeitersparnis für Nutzende.
    $durationMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
    $sourceGroups = if ($null -ne $assistantMessage) { @((Get-PropertyValue -Object $assistantMessage -Name 'sources' -Default @())).Count } else { $null }
    # Die bereits im erfolgreichen Lauf extrahierten Kontexte verwenden; keine zweite Extraktion außerhalb des Fehlerblocks.
    $contextCount = if ($null -ne $assistantMessage) { @($contexts).Count } else { $null }
    $usage = if ($null -ne $assistantMessage) { Get-PropertyValue -Object $assistantMessage -Name 'usage' } else { $null }

    $metadata = [ordered]@{
        run_label = $RunLabel
        fragen_id = $questionId
        reference_card_file = $cardFile.Name
        pruefstatus = $reviewStatus
        chat_id = $chatId
        assistant_message_id = $assistantMessageId
        start_utc = $startUtc.ToString('o')
        end_utc = $endUtc.ToString('o')
        end_to_end_duration_ms = $durationMs
        submit_http_status = $httpStatus
        source_groups_reported = $sourceGroups
        context_chunks_reported = $contextCount
        usage_reported_by_openwebui = $usage
        status = $status
        note = $note
        retrieved_context_verified = $false
        retrieved_context_note = 'Die Abschnitte wurden aus assistant.sources.document des gespeicherten Open-WebUI-Chats extrahiert. Die finale Promptübergabe an das Modell wurde damit nicht unabhängig bewiesen.'
    }
    Write-JsonFile -Path (Join-Path $caseDirectory 'run_metadata.json') -Object $metadata

    $records.Add([pscustomobject]@{
        run_label = $RunLabel
        fragen_id = $questionId
        status = $status
        chat_id = $chatId
        start_utc = $metadata.start_utc
        end_utc = $metadata.end_utc
        end_to_end_duration_ms = $durationMs
        source_groups_reported = $sourceGroups
        context_chunks_reported = $contextCount
        reference_card = $cardFile.Name
        note = $note
    })
}

# --- Phase 7: Laufüberblick auf Ebene des gesamten Durchlaufs speichern ---
# Die CSV eignet sich für die deskriptive Auswertung von QA-04, etwa Median, Spannweite und
# Maximum der Ende-zu-Ende-Zeit. Inhaltliche Qualitätsurteile werden daraus nicht abgeleitet.
$records | Export-Csv -LiteralPath (Join-Path $runRoot 'pilot_run_log.csv') -NoTypeInformation -Delimiter ';' -Encoding UTF8
Write-JsonFile -Path (Join-Path $runRoot 'manifest.json') -Object ([ordered]@{
    run_label = $RunLabel
    created_utc = [DateTime]::UtcNow.ToString('o')
    config_file = 'pilot-openwebui-config.used.json'
    note = 'Rohdaten sind pro Fall gespeichert. reported contexts sind keine unabhängig verifizierten finalen Modellprompts.'
})

Write-Host "Fertig. Laufverzeichnis: $runRoot" -ForegroundColor Green
