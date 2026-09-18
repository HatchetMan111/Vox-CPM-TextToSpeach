# VoxCPM — Proxmox LXC Installer + Web UI

Lokale VoxCPM-Installation als **LXC-Container auf Proxmox VE** im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/):
**Einzeiler auf dem Host → Container + App + Web UI + systemd läuft.**

> Upstream: [OpenBMB/VoxCPM](https://github.com/OpenBMB/VoxCPM)
> (Tokenizer-freies TTS: Voice Design, Controllable Cloning, Ultimate Cloning, 30 Sprachen, 48 kHz).
> Die Upstream-**Gradio-Web-UI** (`app.py`) ist die Bedienoberfläche — dort stellt man
> **alles ein**: Referenz-Audio, Control-Instruction, Ultimate-Cloning-Toggle,
> CFG-Scale, LocDiT-Steps, Seed, Denoise, Text-Normalisierung.
> Der Installer hier fragt zusätzlich alle **Container-/Modell-Settings** ab
> (CT-ID, CPU/RAM/Disk, Port, Modell-Variante, Device).

| Feld | Wert |
|---|---|
| App-Name | `voxcpm` |
| Zweck | Mehrsprachiges TTS lokal im LXC (Voice Design + Voice Cloning per Web UI) |
| Tech-Stack | Python 3.11 / PyTorch (CPU-Build) + Gradio (Upstream `app.py`) |
| Upstream-Repo | https://github.com/OpenBMB/VoxCPM |
| Web-UI-Port | `8808` (konfigurierbar, Upstream-Default) |
| Default-Ressourcen | 4 vCPU · 8192 MB RAM · 20 GB Disk · Debian 12 LXC, `onboot: 1` |

## 1 · Installation (Einzeiler auf dem Proxmox-Host als root)

Direkt auf dem Proxmox-Host als root ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Vox-CPM-TextToSpeach/main/install/voxcpm.sh)"
```

Das Script fragt interaktiv ab (mit sinnvollen Defaults):
`CT-ID` (160) · Hostname · vCPU (4) · RAM (8192) · Disk (20G) ·
Storage (`local-lvm`) · Bridge (`vmbr0`, DHCP) · Web-Port (8808) ·
Modell (`openbmb/VoxCPM2`) · Device (`cpu`).

Danach läuft vollautomatisch:
1. Debian-12-Template sicherstellen (`pveam download` falls nötig)
2. `pct create` + `onboot: 1` + Start
3. Installer-Dateien per `pct push` in den Container
4. `install/setup-container.sh` im Container: Systempakete (Python, ffmpeg),
   Upstream-Clone, venv, **CPU-Torch** + `voxcpm`, Config `/etc/voxcpm/voxcpm.conf`,
   systemd-Unit `voxcpm.service` (`enable`, `Restart=always`, `After=network-online.target`)
5. Selbst-Verifikation: `systemctl is-active` + HTTP-Check auf `localhost:8808/`

**Erwartete Ausgabe (Ende):**

```text
[6/7] Verifikation ...
  - Service: active
  - HTTP-Check auf localhost:8808 ...
  - Web UI antwortet.
[7/7] Fertig.
==================================================================
 VoxCPM Web UI: http://192.168.1.60:8808
 ...
==================================================================
 ✅ Fertig! VoxCPM Web UI: http://192.168.1.60:8808
    CT-ID 160 (voxcpm), onboot=1, Service=voxcpm
    Modell: openbmb/VoxCPM2 | Device: cpu
```

Web UI öffnen → Text eingeben → optional Referenz-Audio hochladen +
Control-Instruction setzen → **Generate Speech** → Audio anhören/exportieren.

## 2 · Update

Einfach den Einzeiler erneut ausführen — bei existierender CT-ID wird
automatisch der **Update-Modus** angeboten (Container bleibt, Code + Deps
werden aktualisiert, Service restartet). Idempotent, mehrfach lauffähig.

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Vox-CPM-TextToSpeach/main/install/voxcpm.sh)"
# -> "CT 160 existiert. Setup erneut ausführen (Update)?" -> Ja
```

Modell/Device/Port nachträglich ändern:

```bash
pct exec 160 -- bash -c "echo 'WEB_PORT=8808
MODEL_ID=openbmb/VoxCPM1.5
DEVICE=cpu' > /etc/voxcpm/voxcpm.conf && systemctl restart voxcpm"
```

## 3 · Deinstallation

```bash
pct stop 160 && pct destroy 160
```

## 4 · Reboot-Test (Nachweis Reboot-Sicherheit)

```bash
pct reboot 160
sleep 30
pct exec 160 -- systemctl is-active voxcpm   # -> active
curl -fsS http://<LXC-IP>:8808/ -o /dev/null && echo HTTP-OK
# Web UI im Browser neu laden -> wieder erreichbar
```

Container startet durch `onboot: 1` nach Host-Reboot automatisch;
die Web UI durch `systemctl enable` + `Restart=always`.
(Hinweis: Nach Reboot dauert der erste Seitenaufruf ggf. 1–3 Minuten,
bis Torch + Modell im RAM warm sind.)

## 5 · Debugging (volle Fehlerkette)

- Installer mit Trace: `DEBUG=1 bash -x install/voxcpm.sh`
- Setup im Container: `DEBUG=1 bash -x /opt/voxcpm/setup-container.sh`
- Service-Logs: `pct exec 160 -- journalctl -u voxcpm -f`
- Config prüfen: `pct exec 160 -- cat /etc/voxcpm/voxcpm.conf`
- Sowohl Installer als auch Setup geben bei Fehlern die **komplette Kette** aus:
  Exit-Code, fehlgeschlagener Befehl + Zeile, Funktions-Stack, Journal-Auszug —
  niemals nur die letzte Fehlerzeile.

## 6 · Repo-Struktur

```text
install/voxcpm.sh            Host-Installer (Einzeiler, Community-Scripts-Stil, Variablen oben)
install/setup-container.sh   Setup IM Container (idempotent, set -euo pipefail, CPU-Torch)
systemd/voxcpm.service        systemd-Unit (enable, Restart=always, After=network-online.target)
.env.example                  Beispiel-Config (Port, Modell, Device)
README.md                     diese Datei (Einzeiler + Update/Deinstall/Reboot-Test)
```

## 7 · Hinweise (wichtig!)

- **Leistung:** VoxCPM2 braucht mit GPU ~8 GB VRAM (RTF ~0.3 auf RTX 4090).
  Im **LXC ohne GPU (CPU)** läuft es, aber deutlich langsamer (mehrere Minuten
  pro Satz möglich). Für produktives Arbeiten: **VM mit GPU-Passthrough**
  + `DEVICE=cuda` — das Setup-Script läuft dort unverändert (Debian 12 vorausgesetzt).
- **Modell-Varianten:** `openbmb/VoxCPM2` (empfohlen, 30 Sprachen) ·
  `openbmb/VoxCPM1.5` (~6 GB VRAM, nur zh/en) · `openbmb/VoxCPM-0.5B` (legacy).
- **Erststart:** Beim ersten Generieren lädt das Modell Weights von HuggingFace
  (~GB, dauert Minuten) — die Verifikation wartet bis zu ~5 Minuten (30×10s).
- **Lizenz:** Upstream Apache-2.0, kommerziell nutzbar. Siehe Upstream-Repo
  für Risiken/Limits (Voice-Cloning-Missbrauch, Halluzinationen bei langen Texten).
