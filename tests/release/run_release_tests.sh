#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://release.app.org}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_RETRIES="${MAX_RETRIES:-12}"
RETRY_DELAY="${RETRY_DELAY:-5}"

echo "[1/4] Ejecutando Smoke Tests contra ${BASE_URL}/healthz..."
health_ok=false
for attempt in $(seq 1 "${MAX_RETRIES}"); do
  if response="$(curl -fsS --max-time 10 "${BASE_URL}/healthz" 2>/dev/null)"; then
    if python3 -c 'import json, sys; data = json.loads(sys.argv[1]); sys.exit(0 if data.get("status") == "ok" else 1)' "${response}"; then
      echo "Smoke test /healthz exitoso en intento ${attempt}/${MAX_RETRIES}: ${response}"
      health_ok=true
      break
    fi
  fi
  echo "Intento ${attempt}/${MAX_RETRIES} pendiente; reintentando en ${RETRY_DELAY}s..."
  sleep "${RETRY_DELAY}"
done

if [[ "${health_ok}" != "true" ]]; then
  echo "Error: ${BASE_URL}/healthz no respondió estado saludable tras ${MAX_RETRIES} intentos." >&2
  exit 1
fi

curl -fsS --max-time 10 "${BASE_URL}/ready" >/dev/null
echo "Sonda /ready verificada correctamente."

echo "[2/4] Verificando contrato JSON y codificación UTF-8 en /api/v1/lessons/nahuatl/unidad-1..."
lesson_headers="$(mktemp)"
lesson_body="$(mktemp)"
trap 'rm -f "${lesson_headers}" "${lesson_body}"' EXIT

http_code="$(curl -sS --max-time 15 -D "${lesson_headers}" -o "${lesson_body}" -w '%{http_code}' "${BASE_URL}/api/v1/lessons/nahuatl/unidad-1")"
if [[ "${http_code}" != "200" ]]; then
  echo "Error: /api/v1/lessons/nahuatl/unidad-1 devolvió HTTP ${http_code}." >&2
  exit 1
fi

if ! grep -qiE '^content-type:.*application/json.*charset=utf-8' "${lesson_headers}"; then
  echo "Error: Content-Type no declara application/json con charset=utf-8." >&2
  cat "${lesson_headers}" >&2
  exit 1
fi

python3 - "${lesson_body}" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as fh:
    raw = fh.read()

text = raw.decode("utf-8")
assert "\\u" not in text, "Se detectaron escapes ASCII \\u en la respuesta JSON UTF-8"

for ch in ("ꞌ", "ō", "ā"):
    assert ch in text, f"Falta el carácter UTF-8 esperado: {ch!r}"

payload = json.loads(text)
assert payload.get("lesson_id") == "nahuatl-unidad-1", "lesson_id inesperado"
assert payload.get("encoding") == "UTF-8", "encoding debe ser UTF-8"
assert isinstance(payload.get("items"), list) and len(payload["items"]) >= 4, "items insuficientes"
assert isinstance(payload.get("exercises"), list) and len(payload["exercises"]) >= 3, "exercises insuficientes"
print("Contrato y codificación UTF-8 verificados: saltillo (ꞌ) y macrones (ō, ā) íntegros.")
PY

echo "[3/4] Validando disponibilidad de audio nativo en /api/v1/speech/sample/cualli-tonalli.wav..."
audio_headers="$(mktemp)"
audio_body="$(mktemp)"
trap 'rm -f "${lesson_headers}" "${lesson_body}" "${audio_headers}" "${audio_body}"' EXIT

audio_code="$(curl -sS --max-time 15 -D "${audio_headers}" -o "${audio_body}" -w '%{http_code}' "${BASE_URL}/api/v1/speech/sample/cualli-tonalli.wav")"
if [[ "${audio_code}" != "200" ]]; then
  echo "Error: el audio nativo devolvió HTTP ${audio_code}." >&2
  exit 1
fi

if ! grep -qiE '^content-type:\s*audio/wav' "${audio_headers}"; then
  echo "Error: Content-Type de audio inesperado (se esperaba audio/wav)." >&2
  cat "${audio_headers}" >&2
  exit 1
fi

python3 - "${audio_body}" <<'PY'
import sys

with open(sys.argv[1], "rb") as fh:
    data = fh.read()

assert len(data) >= 44, f"Archivo WAV demasiado pequeño: {len(data)} bytes"
assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", "Cabecera RIFF/WAVE inválida"
print(f"Audio nativo WAV verificado correctamente ({len(data)} bytes).")
PY

echo "[4/4] Ejecutando pruebas de carga k6 (25 VUs / 45s) contra ${BASE_URL}..."
k6 run -e "BASE_URL=${BASE_URL}" "${SCRIPT_DIR}/k6-load-test.js"

echo "Todas las pruebas de verificación en liberación finalizaron con éxito."
