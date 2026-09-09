# Installation: Projekt Kanban Agent mit Firefox, Windows und WSL

Stand: 2026-09-09

Diese Anleitung beschreibt die aktuelle empfohlene Installation für Firefox auf
Windows, wobei der Agent in WSL läuft.

## Komponenten

| Komponente | Aktuelle Quelle | Zweck |
|---|---|---|
| WSL2 | Windows / Microsoft | Linux-Umgebung für Codex |
| Codex CLI | in WSL installieren | eigentlicher Coding-Agent |
| Manager + Bridge | `ecxod/projekt-kanban-agent-manager` Release | Windows-GUI, Firefox Native Messaging, WSL-Relay |
| Firefox Add-on | `ecxod/projekt-kanban-agent-addon` Release | verbindet Projekt Kanban im Browser mit der lokalen Bridge |

Aktuelle Releases:

| Komponente | Version | Download |
|---|---:|---|
| Manager/Bridge | `0.1.8.19` | <https://github.com/ecxod/projekt-kanban-agent-manager/releases/latest> |
| Firefox Add-on | `0.1.8.4` | <https://github.com/ecxod/projekt-kanban-agent-addon/releases/latest> |

Die Versionsnummern von Add-on und Bridge müssen nicht gleich sein. Das Add-on
prüft die Native-Host-Protokollversion, nicht dieselbe Paketversion.

## 1. WSL installieren oder prüfen

In Windows PowerShell:

```powershell
wsl --version
wsl -l -v
```

Wenn WSL noch nicht installiert ist, PowerShell als Administrator öffnen:

```powershell
wsl --install
wsl --update
```

Für eine bestimmte Distribution:

```powershell
wsl --install -d Ubuntu
```

Nach der Installation einmal die Distribution starten und den Linux-Benutzer
anlegen.

## 2. Codex CLI in WSL installieren

In WSL:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
exec "$SHELL" -l
command -v codex
codex --version
codex
```

Beim ersten Start von `codex` anmelden.

Für den Manager ist der richtige Pfad der ausführbare Wrapper, also das Ergebnis
von:

```bash
command -v codex
```

Beispiel aus Christians aktueller Umgebung:

```text
/home/christian/.nvm/versions/node/v22.23.2/bin/codex
```

Nicht verwenden:

```text
/mnt/c/Users/Christian/.codex/bin/wsl/codex
```

Dieser Pfad zeigte in Christians Test eine alte Codex-Version.

Auch nicht den aufgelösten JavaScript-Dateipfad verwenden:

```text
/home/christian/.nvm/versions/node/v22.23.2/lib/node_modules/@openai/codex/bin/codex.js
```

Der Manager erwartet ein ausführbares Agentenprogramm, nicht die interne
JavaScript-Datei.

## 3. Manager und Windows-WSL-Bridge installieren

Vom Manager-Release herunterladen:

```text
projekt-kanban-agent-manager-0.1.8.19-windows-wsl.zip
```

ZIP entpacken und starten:

```text
start-agent-manager.cmd
```

Der obere Starter ist der empfohlene Komfort-Starter. Er ruft intern
`native-host-windows-wsl\start-agent-manager.cmd` auf.

Im Manager:

| Feld | Empfohlener Wert |
|---|---|
| WSL Distribution | installierte Distribution, z.B. `Devuan` oder `Ubuntu` |
| Agent ID | `local-codex` |
| Label | `Codex in WSL` |
| Adapter | `Codex CLI` |
| Executable | Ergebnis von `command -v codex`, z.B. `/home/christian/.nvm/versions/node/v22.23.2/bin/codex` |
| Workspace | Projekt- oder Workspace-Verzeichnis, z.B. `/mnt/c/Users/Christian/projekt-kanban` |
| Sandbox | für normale Arbeit `workspace-write`, für Tests `read-only` |

Danach:

1. `Save Agent Configuration`
2. Release Tab öffnen
3. `Release aktualisieren`
4. `Update Bridge`
5. Manager Tab öffnen
6. `Enable Agent`
7. `Test Connection`

Die installierte Bridge liegt danach unter:

```text
C:\Users\Christian\AppData\Local\ProjektKanbanAgent
```

Diagnose-Log:

```text
C:\Users\Christian\AppData\Local\ProjektKanbanAgent\relay.log
```

Der Manager und die Bridge sind kein Windows-Dienst und kein Linux-Dienst.
Firefox startet den Native Host bei Bedarf über Native Messaging. Codex läuft
nur während eines Tests oder eines bestätigten Agentenlaufs.

## 4. Firefox Add-on installieren

Vom Add-on-Release herunterladen:

```text
projekt-kanban-agent-0.1.8.4-signed.xpi
```

In Firefox:

1. `about:addons` öffnen.
2. Zahnrad-Menü öffnen.
3. `Add-on aus Datei installieren` wählen.
4. `projekt-kanban-agent-0.1.8.4-signed.xpi` auswählen.
5. Installation bestätigen.

Nicht die unsignierte `.xpi` für normale Firefox-Installation verwenden. Die
signierte Datei heißt:

```text
projekt-kanban-agent-0.1.8.4-signed.xpi
```

Ein kompletter Firefox-Neustart soll normalerweise nicht nötig sein. Wenn
Firefox noch eine alte Native-Host-Verbindung hält, zuerst das Add-on
deaktivieren/aktivieren oder die Add-on-Seite schließen und neu öffnen.

## 5. Funktionstest

Im Add-on sollte sinngemäß stehen:

```text
Native Host 0.1.8.19 verbunden
```

Im Manager:

```text
Test Connection
```

Erwartetes Ergebnis:

| Schritt | Erwartung |
|---|---|
| Firefox Add-on | erreicht Native Host |
| Windows Relay | startet WSL-Host |
| WSL-Host | liest Agent-Konfiguration |
| Codex CLI | wird im konfigurierten Workspace gestartet |
| Antwort | erscheint im Manager-Log oder als Add-on/Windows-Popup |

Wenn der Test meldet, dass Codex zu alt ist, im Manager den Codex-Pfad prüfen.
Meist ist dann versehentlich der alte Windows-Wrapper statt des aktuellen
WSL-Wrappers eingetragen.

## 6. Update

Manager/Bridge:

1. Manager starten.
2. Release Tab öffnen.
3. `Release aktualisieren`.
4. `Update Bridge`.

Firefox Add-on:

1. Add-on-Einstellungen öffnen.
2. GitHub-Releases aktualisieren.
3. die aktuelle signierte `.xpi` installieren.

## 7. Deinstallation

Im Manager im Release Tab:

```text
Uninstall Windows Bridge
```

Alternativ PowerShell im entpackten Manager-Paket:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\native-host-windows-wsl\uninstall.ps1
```

Die lokale Agent-Konfiguration und Laufhistorie werden nicht absichtlich
gelöscht.
