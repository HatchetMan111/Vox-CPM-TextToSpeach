#!/usr/bin/env bash
# =============================================================================
# VoxCPM — Container-Setup (läuft IM LXC, Debian 12, als root)
# Wird vom Host-Installer per pct push + pct exec aufgerufen oder manuell:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Vox-CPM-TextToSpeach/main/install/setup-container.sh | bash
# Idempotent: kann mehrfach laufen (venv wiederverwenden, Pakete updaten).
# Debugging: DEBUG=1 bash -x setup-container.sh  -> volles Trace-Log
# =============================================================================
set -euo pipefail

# --- Variablen (oben, Community-Scripts-Stil) ---------------------------------
APP="voxcpm"
BASE_DIR="/opt/voxcpm"
APP_SRC_DIR="${BASE_DIR}/app-src"          # Upstream-Clone (OpenBMB/VoxCPM, für app.py + assets)
VENV_DIR="${BASE_DIR}/venv"
WEB_PORT="${WEB_PORT:-8808}"
WEB_HOST="${WEB_HOST:-0.0.0.0}"
MODEL_ID="${MODEL_ID:-openbmb/VoxCPM2}"
DEVICE="${DEVICE:-cpu}"                    # cpu (LXC-Default) | auto | cuda | cuda:0 | mps
PYTHON_BIN="${PYTHON_BIN:-python3}"
UPSTREAM_REPO="https://github.com/OpenBMB/VoxCPM.git"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
SERVICE_NAME="voxcpm"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="/etc/voxcpm/voxcpm.conf"
TORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"

# --- Fehlerkette: immer VOLL ausgeben, nie nur letzte Zeile -------------------
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Setup fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "--- Befehl / Kontext ---" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" >&2
  echo "--- Stacktrace ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- Relevante Logs ---" >&2
  journalctl -u "${SERVICE_NAME}" --no-pager -n 80 2>&1 | tail -n 80 >&2 || true
  echo "--- venv / python ---" >&2
  "${VENV_DIR}/bin/python" --version 2>&1 | tail -n 5 >&2 || true
  "${VENV_DIR}/bin/pip" list 2>&1 | grep -iE "voxcpm|torch|gradio|funasr" | tail -n 20 >&2 || true
  echo "Tipp: Re-Run mit Debug-Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR

if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi

echo "[1/7] Systempakete ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  "${PYTHON_BIN}" "${PYTHON_BIN}-venv" "${PYTHON_BIN}-dev" \
  git curl ca-certificates build-essential ffmpeg libsndfile1

echo "[2/7] Verzeichnisse + Config ..."
mkdir -p "${BASE_DIR}" /etc/voxcpm
cat > "${CONFIG_FILE}" <<EOF
# VoxCPM LXC-Konfiguration (wird vom systemd-Service gelesen)
WEB_HOST=${WEB_HOST}
WEB_PORT=${WEB_PORT}
MODEL_ID=${MODEL_ID}
DEVICE=${DEVICE}
EOF
chmod 644 "${CONFIG_FILE}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
echo "  - Config: HOST=${WEB_HOST} PORT=${WEB_PORT} MODEL=${MODEL_ID} DEVICE=${DEVICE}"

echo "[3/7] Upstream VoxCPM klonen/aktualisieren (für app.py + assets) ..."
if [[ -d "${APP_SRC_DIR}/.git" ]]; then
  git -C "${APP_SRC_DIR}" fetch --all --prune
  git -C "${APP_SRC_DIR}" checkout "${UPSTREAM_BRANCH}" 2>/dev/null || true
  git -C "${APP_SRC_DIR}" pull --ff-only || git -C "${APP_SRC_DIR}" reset --hard "origin/${UPSTREAM_BRANCH}"
else
  rm -rf "${APP_SRC_DIR}"
  git clone --depth 1 --branch "${UPSTREAM_BRANCH}" "${UPSTREAM_REPO}" "${APP_SRC_DIR}"
fi
[[ -f "${APP_SRC_DIR}/app.py" ]] || { echo "app.py fehlt in ${APP_SRC_DIR}!" >&2; ls -la "${APP_SRC_DIR}" >&2; exit 1; }

echo "[4/7] venv + Abhängigkeiten (idempotent, CPU-Build für LXC) ..."
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/pip" install --upgrade pip wheel
# Zuerst CPU-Torch, damit pip NICHT die ~2GB CUDA-Wheels zieht (LXC ohne GPU).
"${VENV_DIR}/bin/pip" install --index-url "${TORCH_INDEX_URL}" "torch>=2.5.0" "torchaudio>=2.5.0" || {
  echo "WARN: CPU-Torch-Install schlug fehl, versuche Standard-Index ..." >&2
  "${VENV_DIR}/bin/pip" install "torch>=2.5.0" "torchaudio>=2.5.0"
}
"${VENV_DIR}/bin/pip" install "voxcpm" soundfile funasr modelscope "gradio>=6,<7" huggingface-hub
"${VENV_DIR}/bin/python" -c "import voxcpm, gradio, soundfile; print('imports OK:', voxcpm.__file__)"
"${VENV_DIR}/bin/python" -c "import torch; print('torch:', torch.__version__, '| cuda_available:', torch.cuda.is_available())"

echo "[5/7] systemd-Unit ..."
# Unit aus Wrapper-Repo übernehmen (liegt per pct push unter repo-files/), Fallback: generieren.
if [[ -f "${BASE_DIR}/repo-files/systemd/voxcpm.service" ]]; then
  cp "${BASE_DIR}/repo-files/systemd/voxcpm.service" "${SERVICE_FILE}"
elif [[ -f "./systemd/voxcpm.service" ]]; then
  cp "./systemd/voxcpm.service" "${SERVICE_FILE}"
else
  cat > "${SERVICE_FILE}" <<EOF2
[Unit]
Description=VoxCPM TTS Web UI (Gradio)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONFIG_FILE}
ExecStart=${VENV_DIR}/bin/python ${APP_SRC_DIR}/app.py --host \${WEB_HOST} --port \${WEB_PORT} --device \${DEVICE} --model-id \${MODEL_ID}
WorkingDirectory=${APP_SRC_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2
fi
# Die mitgelieferte Unit nutzt bereits die korrekten Pfade + EnvironmentFile;
# hier nur sicherstellen, dass kein veralteter Port/Host hart verdrahtet ist.
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "[6/7] Verifikation ..."
sleep 5
echo "  - Service: $(systemctl is-active "${SERVICE_NAME}")"
systemctl is-active --quiet "${SERVICE_NAME}" || {
  echo "Service läuft NICHT. Journal:" >&2
  journalctl -u "${SERVICE_NAME}" --no-pager -n 100 >&2
  exit 1
}
echo "  - HTTP-Check auf localhost:${WEB_PORT} (Gradio braucht beim Erststart Minuten für Modell-Download) ..."
OK=0
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${WEB_PORT}/" 2>&1 | grep -qiE "gradio|voxcpm"; then
    echo; echo "  - Web UI antwortet."
    OK=1
    break
  fi
  # Fallback: reiner TCP-/HTTP-200-Check (Gradio-Chunks laden lazy)
  if curl -fsS -o /dev/null "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null; then
    echo; echo "  - Web UI antwortet (HTTP 200)."
    OK=1
    break
  fi
  echo "    Versuch ${i}/30: noch nicht bereit (Modell-Download läuft ggf. noch) ..."
  sleep 10
done
if [[ "${OK}" != "1" ]]; then
  echo "Web UI antwortet NICHT nach 30 Versuchen. Journal + Probe:" >&2
  journalctl -u "${SERVICE_NAME}" --no-pager -n 100 >&2
  curl -v "http://127.0.0.1:${WEB_PORT}/" >&2 || true
  exit 1
fi

CT_IP="$(hostname -I | awk '{print $1}')"
echo "[7/7] Fertig."
echo "=================================================================="
echo " VoxCPM Web UI: http://${CT_IP}:${WEB_PORT}"
echo " Service: systemctl status ${SERVICE_NAME}"
echo " Config: ${CONFIG_FILE}"
echo " Modell: ${MODEL_ID} | Device: ${DEVICE}"
echo "=================================================================="
