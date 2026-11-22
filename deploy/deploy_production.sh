#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "Uso: $0 <IMAGE_TAG>" >&2
  exit 1
fi

IMAGE_TAG="$1"
NAMESPACE="${NAMESPACE:-prod}"
RELEASE_NAME="${RELEASE_NAME:-app-prod}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/org/app-cicd}"
STABILIZATION_SECONDS="${STABILIZATION_SECONDS:-45}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus-server.monitoring.svc.cluster.local:9090}"
MAX_5XX_ERROR_RATE="${MAX_5XX_ERROR_RATE:-0.001}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[1/4] Verificando namespace '${NAMESPACE}' en el clúster..."
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

echo "[2/4] Desplegando '${RELEASE_NAME}' (${IMAGE_REPOSITORY}:${IMAGE_TAG}) en namespace '${NAMESPACE}'..."
cd "${REPO_ROOT}"
helm upgrade --install app-prod ./deploy/helm \
  --namespace prod \
  --values ./deploy/helm/values-prod.yaml \
  --set "image.repository=${IMAGE_REPOSITORY}" \
  --set "image.tag=${IMAGE_TAG}" \
  --atomic \
  --wait \
  --timeout 10m0s

echo "[3/4] Esperando ${STABILIZATION_SECONDS}s de estabilización post-despliegue..."
sleep "${STABILIZATION_SECONDS}"

echo "[4/4] Consultando tasa de errores HTTP 5xx en los últimos 2 minutos en Prometheus..."
PROMQL_QUERY='sum(rate(http_requests_total{namespace="prod",status=~"5.."}[2m])) / clamp_min(sum(rate(http_requests_total{namespace="prod"}[2m])), 1)'

prom_response="$(curl -fsS --max-time 15 --get \
  --data-urlencode "query=${PROMQL_QUERY}" \
  "${PROMETHEUS_URL%/}/api/v1/query")"

error_rate="$(python3 - "${prom_response}" <<'PY'
import json
import math
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") != "success":
    raise SystemExit(f"Consulta Prometheus fallida: {payload}")

results = payload.get("data", {}).get("result", [])
if not results:
    print("0.0")
    sys.exit(0)

value = float(results[0]["value"][1])
if math.isnan(value) or math.isinf(value):
    value = 0.0
print(f"{value:.6f}")
PY
)"

echo "Tasa de errores HTTP 5xx medida: ${error_rate} (umbral máximo permitido: ${MAX_5XX_ERROR_RATE})."

if awk -v rate="${error_rate}" -v limit="${MAX_5XX_ERROR_RATE}" 'BEGIN { exit (rate > limit) ? 0 : 1 }'; then
  echo "ALERTA SRE: Tasa de errores 5xx (${error_rate}) supera ${MAX_5XX_ERROR_RATE}. Ejecutando rollback automático..." >&2
  helm rollback app-prod 0 --namespace prod --wait
  echo "Rollback de app-prod completado en namespace prod." >&2
  exit 1
fi

echo "Despliegue en producción verificado dentro de SLO (tasa 5xx=${error_rate} <= ${MAX_5XX_ERROR_RATE})."
