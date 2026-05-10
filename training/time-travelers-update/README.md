# Rogue Update

> **Category:** Advanced Security | **Points:** 500
>
> **MITRE ATT&CK for ICS:** `Impair Process Control / Modify Firmware` | `Initial Access / Valid Accounts` | `Discovery / Network Sniffing` | `Command and Control / Application Layer Protocol`

---

## The Scenario

*Somewhere in a small town in southern Germany, a distribution box hums quietly. Inside: an STM32 microcontroller that has dutifully done its job for years. Once a month — or more often if the vendor pushes a patch — it automatically downloads new firmware from the internal update server. No one watches. The daemon simply asks every 30 seconds: "Anything new for me?"*

*Today, you are the answer.*

---

PhysLab Industries operates an internal OT network behind an OpenWrt gateway router. The external maintenance network — originally intended only for field technicians — is reachable from the outside. The firewall rules were "temporarily" loosened, an intern set the router password, and no one has changed it since.

The firmware update channel is cryptographically protected — *or at least that’s what the developer who built it believes.* The MAC is delivered together with the download, and the daemon checks it before flashing. What she missed: the MAC scheme in use has a known weakness. If you know the MAC and the secret length, you can append new payloads — without knowing the key.

Your mission: break into the gateway, take over the firmware update channel from the inside — and before the daemon asks again, be the answer.

**The countdown is running. 30 seconds.**

---

## Network Topology

```
You (Kali / ext_ctf)
172.22.0.100
     |
     |  ext_ctf (172.22.0.0/24)
     |
OpenWrt Router (QEMU in Docker)
     external: 172.22.0.2   (SSH :2222, HTTP :8080)
     internal: 172.18.0.50  (Bridge into ICS network)
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

The internal ICS network is **not reachable** without pivoting through the router.

---

## Attack Chain at a Glance

```
Phase 1: Recon in the external network
    → Find router IP and open ports

Phase 2: Initial Access
    → SSH brute-force against the router

Phase 3: Traffic analysis on the router
    → Sniff periodic update requests and identify the target

Phase 4: Analyze update mechanism
    → Explore API endpoints, find documentation

Phase 5: Download firmware and MAC
    → Obtain firmware image and original MAC

Phase 6: Forge MAC
    → Length extension attack against MD5(secret || firmware)

Phase 7: Inject manipulated firmware
    → Start rogue server, redirect DNS
```

---

## Phase 1 — Reconnaissance

You start in the `ext_ctf` network (`172.22.0.0/24`). The only externally reachable connection used by PhysLab Industries’ field service — and one that nobody has properly locked down since the last audit.

### Task
Scan the external network for active hosts and open services.

<details>
<summary>Hint</summary>
You should find one host with two open services — including SSH on a non-standard port.
</details>

---

## Phase 2 — Initial Access: SSH Brute Force

The router runs OpenWrt. The root password was set by an intern — short, memorable, and never checked against any password policy.

### Task
Gain access to the router via SSH brute-force. Watch the correct port.

<details>
<summary>Hint</summary>

The password is short. You don’t need a huge wordlist — a small one is enough. Check what is available on your Kali machine under `/usr/share/dirb/wordlists/`.

> **Tip:** OpenWrt includes `opkg` — the router’s package manager. With `opkg update && opkg install <package>`, many tools can be installed afterward (e.g., `tcpdump`, `curl`, `python3`).

</details>

---

## Phase 3 — Traffic Analysis on the Router

You are on the router. From here, you can see the internal ICS network `172.18.0.0/24` — your attacker laptop cannot. What flows here, stays here.

Listen to network traffic on the internal interface. Something in the network behaves strangely — regularly, every 30 seconds.

### Task
Identify the internal host that sends periodic HTTP requests and determine its target.

<details>
<summary>Hint</summary>

```bash
# On the router (via SSH):
tcpdump -i <interface> -n
```

Wireshark can process tcpdump streams live over an SSH pipe — making analysis much more convenient.

You will notice that `172.18.0.8` repeatedly tries to reach a specific internal server. Note the IP and port — that is your next target.

</details>

---

## Phase 4 — Analyze the Update Mechanism

You now know the update server. Time to map its surface.

Many internal servers in OT environments run with developer defaults — including interactive API documentation that has no place in production.

### Task
Explore the update server and determine which endpoints it offers and how requests must be structured.

<details>
<summary>Hint</summary>

Use a fuzzing tool of your choice to discover possible endpoints.

One specific directory tells you everything: available endpoints, expected parameters — and the length of a certain secret.

> **Tip:** To reach the update server from your Kali network, you need a tunnel through the router. Check which SSH options can help with that.

</details>

---

## Phase 5 — Download Firmware and MAC

The server provides firmware images for download. During download, something interesting happens: the response includes not only the firmware — it reveals something about the verification mechanism.

### Task
Download the current firmware and extract the MAC from the HTTP response.

<details>
<summary>Hint</summary>

```bash
curl http://172.18.0.9:<port>/api/v1/firmware/download/<version> \
     -D headers.txt -o firmware.bin
```

Read the response headers carefully. One of them contains the MAC value used by the daemon for verification. You will need it.

</details>

---

## Phase 6 — Forge the MAC: Length Extension Attack

Firmware verification uses `MD5(secret || firmware)`. That sounds secure — but it isn’t.

This scheme is vulnerable to a **length extension attack**: with the known MAC and the secret length, you can produce a valid MAC for `firmware || padding || your_payload` — *without ever knowing the key*.

### Task
Append your own payload to the firmware and calculate a valid MAC for it.

<details>
<summary>Hint</summary>

The tool `hash_extender` is built exactly for this attack. You need:
- the original MAC from Phase 5
- the firmware from Phase 5
- the key length (revealed by the API documentation)
- your payload

The result: a manipulated firmware file and a new MAC that the daemon will accept.

</details>

---

## Phase 7 — Inject the Manipulated Firmware

Every 30 seconds, the daemon queries: `update.cybics` — a hostname. This name is resolved by the router’s DNS. You control the router. That is enough.

The elegant approach: run the rogue server not on your attacker machine, but *on the router itself*. The daemon asks localhost — and gets your firmware.

### Task
Copy your manipulated firmware and a server script to the router or attacker machine, start the rogue server, and redirect DNS resolution.

<details>
<summary>Hint</summary>

You can use the following Python HTTP server code as a template:
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

If everything works, you will see the flag in the logs of the `firmware-updater` Docker container.

</details>

---

## Flag

```
CybICS(m4lic1Ous_FIRMwar3_update)
```

---

## Security Insights

This challenge illustrates an attack chain that can be found similarly in real ICS environments:

| Vulnerability                       | Impact | Mitigation |
|-------------------------------------|---|---|
| Weak router password                | Initial access via brute-force | Strong, unique credentials; no default passwords |
| `MD5(secret \|\| data)` as MAC      | Length extension attack without key | Use HMAC (e.g., HMAC-SHA256) |
| HTTP instead of HTTPS for updates   | Traffic analysis / man-in-the-middle | TLS with certificate validation |
| Missing firmware signature          | Arbitrary firmware injection | Asymmetric signatures (e.g., Ed25519) + secure boot |
| Exposed API documentation           | Easier endpoint discovery | Deploy production without `/docs` endpoint |
| Router access                       | DNS spoofing possible | Minimal write permissions; read-only root filesystem |

---

## MITRE ATT&CK for ICS Mapping

| Tactic | Technique | Description |
|---|---|---|
| Initial Access | Valid Accounts | SSH brute-force against the gateway router |
| Discovery | Network Sniffing | tcpdump on internal router interface |
| Discovery | Remote System Discovery | Update server reconnaissance via ffuf |
| Command and Control | Application Layer Protocol | HTTP-based firmware update channel |
| Impair Process Control | Modify Firmware | Firmware image manipulation via length extension |
| Execution | — | Execution through automated flashing process |
