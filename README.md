# RAGnar - ein lokaler RAG-Assistenz für internes MediaWiki Inhalte

Dieses Repository enthält die Docker-Compose-Konfiguration und PowerShell-Skripte zur Bereitstellung eines lokalen RAG-Prototyps im Rahmen einer Bachelorarbeit.

Die README beschreibt die Laufzeitumgebung, die Erzeugung des Anwendungsschlüssels, den Containerstart und den Download der Modelle. Die Auswahl und Konfiguration der RAG-Verarbeitung, die Promptvorlagen sowie die technische Erprobung und Pilotierung werden in der Bachelorarbeit beschrieben.

## 1. Host- und GPU-Umgebung

Der Prototyp wird auf einer Ubuntu-Serverumgebung mit einer NVIDIA A10 betrieben.

| Komponente | Voraussetzung beziehungsweise verwendeter Stand |
| --- | --- |
| Betriebssystem | Ubuntu 24.04 LTS |
| GPU | NVIDIA A10 mit 24 GB VRAM |
| GPU-Treiber | Auf dem Host installierter, zur GPU passender NVIDIA-Treiber |
| Container-Laufzeit | Docker Engine mit Docker-Compose-Plugin |
| Compose-Version | Mindestens 2.30.0 für die verwendete Angabe `gpus: all` |
| GPU-Anbindung | NVIDIA Container Toolkit, für Docker konfiguriert |
| Hilfsprogramme | curl, OpenSSL und GnuPG |
| Ollama | Container-Image `ollama/ollama:0.33.0` |
| Open WebUI | Container-Image `ghcr.io/open-webui/open-webui:v0.11.4` |

Für die Installation sind Administratorrechte auf dem Ubuntu-Host und Internetzugriff zum Download der Pakete, Container-Images und Modelle erforderlich. Die folgenden Docker-Befehle verwenden sudo.

### NVIDIA-Treiber und Docker prüfen

Auf dem Ubuntu-Host ausführen:

```bash
nvidia-smi
sudo docker version
sudo docker compose version
```

Die Ausgabe von nvidia-smi muss die NVIDIA A10 anzeigen. Fehlt der Treiber, wird er zunächst gemäß der [Ubuntu-Anleitung zur NVIDIA-Treiberinstallation](https://documentation.ubuntu.com/server/how-to/graphics/install-nvidia-drivers/) eingerichtet.

Docker Engine und das Compose-Plugin werden bei Bedarf gemäß der [Docker-Installationsanleitung für Ubuntu](https://docs.docker.com/engine/install/ubuntu/) installiert.


## 1. Projektverzeichnis und Compose-Datei

Die [Compose-Datei](./compose.yaml) liegt im Hauptverzeichnis des Repositorys. Alle nachfolgenden Befehle für die Schlüsselerzeugung und Docker Compose werden in diesem Verzeichnis auf dem Ubuntu-Host ausgeführt.

Die Datei definiert die Dienste ollama und open-webui, deren persistente Volumes und das gemeinsame Docker-Netzwerk. Die Deklarationen der benannten Volumes und des Netzwerks müssen ebenfalls in der Compose-Datei enthalten sein.

## 2. WEBUI_SECRET_KEY und .env erzeugen

Open WebUI benötigt einen stabilen internen Anwendungsschlüssel. Für jede neue Installation wird ein eigener Schlüssel erzeugt und in der lokalen Datei .env gespeichert. Docker Compose übergibt diesen Wert an den Open-WebUI-Container.

Die folgenden Befehle erzeugen 32 kryptografisch zufällige Bytes als Hexadezimalzeichenfolge und schreiben den Schlüssel ohne Ausgabe auf dem Terminal in die Datei. Eine bestehende .env wird nicht überschrieben.

```bash
if [ -e .env ]; then
  printf '%s\n' '.env ist bereits vorhanden und wird nicht überschrieben.'
else
  (
    umask 077
    set -o noclobber
    prototype_webui_secret="$(openssl rand -hex 32)" || exit 1
    printf 'WEBUI_SECRET_KEY=%s\n' "$prototype_webui_secret" > .env
  )
fi

chmod 600 .env
```

Eine vorhandene .env muss bereits einen gültigen Eintrag für WEBUI_SECRET_KEY enthalten. Der Schlüssel wird bei Neustarts und Container-Neuerstellungen beibehalten.

Die .env wird nicht in Git veröffentlicht. Im Repository muss die Datei .gitignore deshalb mindestens diesen Eintrag enthalten:

## 3. Container herunterladen und starten

Zunächst die Compose-Konfiguration prüfen, ohne die aufgelösten Schlüsselwerte auszugeben:

```bash
sudo docker compose --env-file .env -f compose.yaml config --quiet
```

Nach erfolgreicher Prüfung die beiden Container-Images herunterladen:

```bash
sudo docker compose --env-file .env -f compose.yaml pull
```

Die Dienste im Hintergrund erstellen und starten:

```bash
sudo docker compose --env-file .env -f compose.yaml up -d --wait --wait-timeout 180
```

Compose legt die definierten Volumes und das Netzwerk an, sofern sie noch nicht vorhanden sind. Bei bestehenden Ressourcen werden diese wiederverwendet. Die Option --wait wartet auf den Status running beziehungsweise healthy, sofern ein Healthcheck vorhanden ist.

Den Zustand der beiden Dienste und die GPU-Anbindung kontrollieren:

```bash
sudo docker compose --env-file .env -f compose.yaml ps
sudo docker exec ollama nvidia-smi
sudo docker exec ollama ollama list
```

Beide Dienste müssen laufen. nvidia-smi muss auch im Ollama-Container die A10 anzeigen. Vor dem Modelldownload darf die Modellliste noch leer sein.

Bei einem fehlgeschlagenen Start die Protokolle prüfen und den Fehler beheben, bevor die weiteren Schritte ausgeführt werden:

```bash
sudo docker compose --env-file .env -f compose.yaml logs --tail=100 ollama open-webui
```

## 4. Ollama-Modelle herunterladen

Der Prototyp verwendet ein Embedding-Modell für die Vektorrepräsentationen und ein Sprachmodell für die Antwortgenerierung.

| Aufgabe | Ollama-Modell |
| --- | --- |
| Embedding-Erzeugung | qwen3-embedding:0.6b |
| Antwortgenerierung | qwen3.5:9b-q4_K_M |

Die Modelle im laufenden Ollama-Container herunterladen:

```bash
sudo docker exec ollama ollama pull qwen3-embedding:0.6b
sudo docker exec ollama ollama pull qwen3.5:9b-q4_K_M
```

Den erfolgreichen Download kontrollieren:

```bash
sudo docker exec ollama ollama list
```

Die Ausgabe muss beide Modellnamen enthalten. Die Modelldateien werden im persistenten Ollama-Volume gespeichert und müssen nach einer Container-Neuerstellung mit demselben Volume nicht erneut heruntergeladen werden.

## 5. Open WebUI aufrufen

Die bereitgestellte Compose-Konfiguration bindet Open WebUI ausschließlich an die Loopback-Adresse der VM. Auf der VM ist die Oberfläche unter [http://127.0.0.1:3000](http://127.0.0.1:3000) erreichbar.

Für den Zugriff von einem anderen Rechner einen SSH-Tunnel öffnen. Diesen Befehl auf dem lokalen Rechner ausführen und SSH_BENUTZER sowie VM_ADRESSE ersetzen:

```bash
ssh -N -L 127.0.0.1:3000:127.0.0.1:3000 SSH_BENUTZER@VM_ADRESSE
```

Solange der Tunnel besteht, ist die Oberfläche im lokalen Browser ebenfalls unter [http://127.0.0.1:3000](http://127.0.0.1:3000) erreichbar.

Damit sind die beiden Laufzeitdienste gestartet und die benötigten Modelle vorhanden. Die Einrichtung des Wissensbestands und der Anwendungseinstellungen erfolgt entsprechend der Bachelorarbeit und den nachfolgenden Skripten.

## 6. PowerShell-Skripte für den Wissensbestand

Die Skripte für den Export, die Aufbereitung und den Import liegen im Verzeichnis scripts/. Die Reihenfolge bildet den vorgesehenen Verarbeitungspfad ab.

| Reihenfolge | Skript | Aufgabe |
| --- | --- | --- |
| 1 | [ExportAllSitesAsHTMLwithMetadata.ps1](./scripts/ExportAllSitesAsHTMLwithMetadata.ps1) | MediaWiki-Inhalte exportieren und Artikelinhalte mit zugehörigen Metadaten bereitstellen. |
| 2 | [NewMetadataFormatAndArticleExclusion.ps1](./scripts/NewMetadataFormatAndArticleExclusion.ps1) | Metadaten aufbereiten und Artikel für den Prototyp als eingeschlossen beziehungsweise ausgeschlossen kennzeichnen. |
| 3 | [MarkdownConversion.ps1](./scripts/MarkdownConversion.ps1) | HTML-Dateien lokal mit MarkItDown in Markdown konvertieren. |
| 4 | [CleanMarkdown_v2.ps1](./scripts/CleanupBearbeitungslinks.ps1) | Entfernt MediaWiki-Bearbeitungslinks und ersetzt die Bild URLs durch absolute Pfade. |
| 5 | [ConvertMetadataForOpenWebUI.ps1](./scripts/ConvertMetadataForOpenWebUI.ps1) | Quellenmetadaten der vorgesehenen Markdown-Dateien für Open WebUI bereitstellen. |
| 6 | [ImportWikiToOpenWebUI.ps1](./scripts/ImportWikiToOpenWebUI.ps1) | Markdown-Dateien und zugehörige Metadaten über die API in eine Open-WebUI-Wissenssammlung importieren. |

Für die Skripte wird PowerShell 7 verwendet. Die Markdown-Konvertierung setzt außerdem Python und MarkItDown voraus. Parameter, Verzeichnisse und Zugangsdaten werden entsprechend den jeweiligen Skripten angepasst. Für den API-Import ist ein eigener Open-WebUI-API-Schlüssel erforderlich.

## Technische Referenzen

- [Docker Engine auf Ubuntu installieren](https://docs.docker.com/engine/install/ubuntu/)
- [GPU-Zuweisung in Docker Compose](https://docs.docker.com/reference/compose-file/services/#gpus)
- [NVIDIA-Treiber unter Ubuntu](https://documentation.ubuntu.com/server/how-to/graphics/install-nvidia-drivers/)
- [NVIDIA Container Toolkit installieren und für Docker konfigurieren](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [Docker Compose: Dienste erstellen und starten](https://docs.docker.com/reference/cli/docker/compose/up/)
- [Ollama im Docker-Container betreiben](https://docs.ollama.com/docker)

