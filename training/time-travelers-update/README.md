# Rogue Update

> **Kategorie:** Advanced Security | **Punkte:** 500
>
> **MITRE ATT&CK for ICS:** `Impair Process Control / Modify Firmware` | `Initial Access / Valid Accounts` | `Discovery / Network Sniffing` | `Command and Control / Application Layer Protocol`

---

## Das Szenario

*Irgendwo in einer süddeutschen Kleinstadt brummt ein Verteilerkasten vor sich hin. Drinnen: ein STM32-Mikrocontroller, der seit Jahren brav seinen Dienst tut. Einmal im Monat — oder öfter, wenn der Hersteller einen Patch schiebt — lädt er sich automatisch neue Firmware vom internen Update-Server. Kein Mensch schaut zu. Der Daemon fragt einfach alle 30 Sekunden: „Gibt's was Neues für mich?"*

*Heute bist du die Antwort.*

---

PhysLab Industries betreibt hinter einem OpenWrt-Gateway-Router ein internes OT-Netz. Das externe Wartungsnetz — eigentlich nur für den Außendienst gedacht — ist von außen erreichbar. Die Firewall-Regeln wurden „vorübergehend" gelockert, der Praktikant hat das Router-Passwort gesetzt und niemand hat es seitdem geändert.

Der Firmware-Update-Kanal ist kryptografisch geschützt — *oder zumindest glaubt das die Entwicklerin, die ihn aufgebaut hat.* Der MAC wird beim Download mitgeliefert, der Daemon prüft ihn vor dem Flashen. Was sie übersehen hat: Das verwendete MAC-Schema hat eine bekannte Schwäche. Wer den MAC und die Länge des Secrets kennt, kann neue Payloads anhängen — ganz ohne den Schlüssel.

Deine Mission: Einbruch in das Gateway, Übernahme des Firmware-Update-Kanals von innen heraus — und bevor der Daemon das nächste Mal fragt, bist du die Antwort.

**Der Countdown läuft. 30 Sekunden.**

---

## Netzwerk-Topologie

```
Du (Kali / ext_ctf)
172.22.0.100
     |
     |  ext_ctf (172.22.0.0/24)
     |
OpenWrt Router (QEMU in Docker)
     extern:  172.22.0.2   (SSH :2222, HTTP :8080)
     intern:  172.18.0.50  (Brücke ins ICS-Netz)
     |
     |  virtual_virt-cybics (172.18.0.0/24)
     |
     +--- HWIO          172.18.0.2
     +--- OpenPLC       172.18.0.3
     +--- FUXA HMI      172.18.0.4
     +--- OPC-UA        172.18.0.5
     +--- S7COM         172.18.0.6
     +--- STM32         172.18.0.7
     +--- Firmware-Upd. 172.18.0.8
     +--- Update-Server 172.18.0.9
```

Das interne ICS-Netz ist ohne Pivot über den Router **nicht erreichbar**.

---

## Angriffskette auf einen Blick

```
Phase 1: Recon im externen Netz
    → Router-IP und offene Ports finden

Phase 2: Initial Access
    → SSH-Brute-Force gegen den Router

Phase 3: Traffic-Analyse auf dem Router
    → Periodische Update-Anfragen belauschen und Ziel identifizieren

Phase 4: Update-Mechanismus analysieren
    → API-Endpunkte erkunden, Dokumentation finden

Phase 5: Firmware und MAC herunterladen
    → Firmware-Image und originale MAC beschaffen

Phase 6: MAC fälschen
    → Length Extension Attack gegen MD5(secret || firmware)

Phase 7: Manipulierte Firmware einschleusen
    → Rogue-Server starten, DNS umbiegen
```

---

## Phase 1 — Reconnaissance

Du startest im `ext_ctf`-Netz (`172.22.0.0/24`). Die einzige Verbindung zur Außenwelt, die der Außendienst von PhysLab Industries nutzt — und die seit dem letzten Audit niemand mehr richtig gesperrt hat.

### Aufgabe
Scanne das externe Netz nach aktiven Hosts und offenen Diensten.

<details>
<summary>Hinweis</summary>
Du solltest einen Host mit zwei offenen Diensten finden — darunter einen SSH-Dienst auf einem nicht-standardmäßigen Port.
</details>

---

## Phase 2 — Initial Access: SSH-Brute-Force

Der Router läuft auf OpenWrt. Das Root-Passwort hat ein Praktikant gesetzt — kurz, einprägsam, und in keiner Passwortrichtlinie je geprüft.

### Aufgabe
Erlange per SSH-Brute-Force Zugang zum Router. Achte auf den richtigen Port.

<details>
<summary>Hinweis</summary>

Das Passwort ist kurz. Du brauchst keine riesige Wörterbuchliste — eine kleine reicht. Schau, was auf deiner Kali-Maschine unter `/usr/share/dirb/wordlists/` bereitliegt.

> **Tipp:** OpenWrt bringt `opkg` mit — den Paketmanager des Routers. Mit `opkg update && opkg install <paket>` lassen sich viele Tools nachinstallieren (z. B. `tcpdump`, `curl`, `python3`).

</details>

---

## Phase 3 — Traffic-Analyse auf dem Router

Du bist auf dem Router. Von hier aus hast du Sicht ins interne ICS-Netz `172.18.0.0/24` — dein Angreifer-Laptop dagegen ist blind. Was hier fließt, bleibt hier.

Lausche dem Netzwerkverkehr auf der internen Schnittstelle. Irgendwas im Netz verhält sich seltsam — regelmäßig, alle 30 Sekunden.

### Aufgabe
Identifiziere den internen Host, der periodische HTTP-Anfragen aussendet, und ermittle sein Ziel.

<details>
<summary>Hinweis</summary>

```bash
# Auf dem Router (via SSH):
tcpdump -i <interface> -n
```

Wireshark kann tcpdump-Streams live über eine SSH-Pipe verarbeiten — das macht die Analyse komfortabler.

Du wirst feststellen, dass `172.18.0.8` in regelmäßigen Abständen versucht, einen bestimmten internen Server zu erreichen. Notiere dir IP und Port — das ist dein nächstes Ziel.

</details>

---

## Phase 4 — Update-Mechanismus analysieren

Du kennst jetzt den Update-Server. Zeit, seine Oberfläche zu kartieren.

Viele interne Server in OT-Umgebungen werden mit Entwickler-Defaults betrieben — inklusive interaktiver API-Dokumentation, die im Produktivbetrieb nichts verloren hat.

### Aufgabe
Erkunde den Update-Server und finde heraus, welche Endpunkte er anbietet und wie Anfragen aufgebaut sein müssen.

<details>
<summary>Hinweis</summary>

Verwende ein Fuzzing-Tool deiner Wahl, um mögliche Endpunkte aufzuspüren.

Ein bestimmtes Verzeichnis verrät dir alles: verfügbare Endpunkte, erwartete Parameter — und die Länge eines bestimmten Secrets.

> **Tipp:** Um den Update-Server aus deinem Kali-Netz zu erreichen, brauchst du einen Tunnel durch den Router. Schau, welche SSH-Optionen dir dabei helfen können.

</details>

---

## Phase 5 — Firmware und MAC herunterladen

Der Server stellt Firmware-Images zum Download bereit. Beim Download passiert etwas Interessantes: Der Response enthält nicht nur die Firmware — er verrät auch etwas über den Verifikationsmechanismus.

### Aufgabe
Lade die aktuelle Firmware herunter und extrahiere den MAC aus dem HTTP-Response.

<details>
<summary>Hinweis</summary>

```bash
curl http://172.18.0.9:<port>/api/v1/firmware/download/<version> \
     -D headers.txt -o firmware.bin
```

Lies die Response-Header sorgfältig. Einer davon enthält den MAC-Wert, den der Daemon zur Verifikation einsetzt. Du wirst ihn brauchen.

</details>

---

## Phase 6 — MAC fälschen: Length Extension Attack

Die Firmware-Verifikation nutzt `MD5(secret || firmware)`. Das klingt sicher — ist es aber nicht.

Das Schema ist anfällig für einen **Length Extension Attack**: Mit dem bekannten MAC und der Länge des Secrets kannst du einen gültigen MAC für `firmware || padding || dein_payload` erzeugen — *ganz ohne den Schlüssel zu kennen*.

### Aufgabe
Hänge einen eigenen Payload an die Firmware an und berechne einen gültigen MAC dafür.

<details>
<summary>Hinweis</summary>

Das Tool `hash_extender` ist für genau diesen Angriff gebaut. Du brauchst:
- den originalen MAC aus Phase 5
- die Firmware aus Phase 5
- die Schlüssellänge (die API-Dokumentation hat sie dir verraten)
- deinen Payload

Das Ergebnis: eine manipulierte Firmware-Datei und ein neuer MAC, den der Daemon akzeptieren wird.

</details>

---

## Phase 7 — Manipulierte Firmware einschleusen

Der Daemon fragt alle 30 Sekunden: `update.cybics` — ein Hostname. Dieser wird vom DNS des Routers aufgelöst. Du kontrollierst den Router. Das reicht.

Der elegante Weg: Du startest den Rogue-Server nicht auf deiner Angreifer-Maschine, sondern *auf dem Router selbst*. Der Daemon fragt localhost — und bekommt deine Firmware.

### Aufgabe
Kopiere deine manipulierte Firmware und ein Server-Skript auf den Router oder die Angreifer-Maschine, starte den Rogue-Server und biege die DNS-Auflösung um.

<details>
<summary>Hinweis</summary>

Du kannst den folgenden Python-HTTP-Servercode als Vorlage nutzen:
```python
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


VERSION = os.environ.get("FIRMWARE_VERSION", "1.2.1")
FIRMWARE_PATH = Path(
    os.environ.get("FIRMWARE_PATH", "/opt/cybics/update-server/firmware/firmware.bin")
)
FIRMWARE_MAC = os.environ.get("FIRMWARE_MAC", "")


def _json(handler: BaseHTTPRequestHandler, code: int, payload: dict) -> None:
    body = json.dumps(payload).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/v1/firmware/latest":
            return _json(
                self,
                200,
                {
                    "version": VERSION,
                    "mac": FIRMWARE_MAC,
                    "url": f"/api/v1/firmware/download/{VERSION}",
                },
            )

        prefix = "/api/v1/firmware/download/"
        if path.startswith(prefix):
            if path[len(prefix) :] != VERSION:
                return _json(self, 404, {"detail": "Firmware version not found"})
            if not FIRMWARE_PATH.is_file():
                return _json(self, 500, {"detail": "Firmware file is not available"})
            if not FIRMWARE_MAC:
                return _json(self, 500, {"detail": "Firmware MAC is not configured"})

            firmware = FIRMWARE_PATH.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(firmware)))
            self.send_header("X-Firmware-MAC", FIRMWARE_MAC)
            self.end_headers()
            self.wfile.write(firmware)
            return

        _json(self, 404, {"detail": "Not found"})

    def log_message(self, *_: object) -> None:
        pass


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "6689"))
    ThreadingHTTPServer((host, port), Handler).serve_forever()
```

Wenn alles klappt, siehst du die Flag in den Logs vom Docker-Container `firmware-updater`.

</details>

---

## Flag

```
CybICS(m4lic1Ous_FIRMwar3_update)
```

---

## Security Insights

Diese Challenge illustriert eine Angriffskette, die sich so oder ähnlich in echten ICS-Umgebungen findet:

| Schwachstelle                       | Auswirkung | Gegenmaßnahme |
|-------------------------------------|---|---|
| Schwaches Router-Passwort           | Initial Access per Brute-Force | Starke, einzigartige Credentials; keine Default-Passwörter |
| `MD5(secret \|\| data)` als MAC     | Length Extension Attack ohne Key | HMAC verwenden (z. B. HMAC-SHA256) |
| HTTP statt HTTPS für Updates        | Traffic-Analyse / Man-in-the-Middle | TLS mit Zertifikatsvalidierung |
| Fehlende Firmware-Signatur          | Beliebige Firmware einschleusen | Asymmetrische Signaturen (z. B. Ed25519) + Secure Boot |
| Exponierte API-Dokumentation        | Endpoint-Discovery vereinfacht | Produktion ohne `/docs`-Endpunkt deployen |
| Zugriff auf Router | DNS-Spoofing möglich | Minimale Schreibrechte; Read-only-Rootfs |

---

## MITRE ATT&CK for ICS Mapping

| Taktik | Technik | Beschreibung |
|---|---|---|
| Initial Access | Valid Accounts | SSH-Brute-Force gegen den Gateway-Router |
| Discovery | Network Sniffing | tcpdump auf internem Router-Interface |
| Discovery | Remote System Discovery | Erkundung des Update-Servers via ffuf |
| Command and Control | Application Layer Protocol | HTTP-basierter Firmware-Update-Kanal |
| Impair Process Control | Modify Firmware | Manipulation des Firmware-Images via Length Extension |
| Execution | — | Ausführung über automatisierten Flash-Vorgang |
