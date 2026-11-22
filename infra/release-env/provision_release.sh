#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "Uso: $0 <IMAGE_TAG>" >&2
  exit 1
fi

IMAGE_TAG="$1"
NAMESPACE="${NAMESPACE:-release}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/org/app-cicd}"
REDIS_URL="${REDIS_URL:-redis://redis-master.${NAMESPACE}.svc.cluster.local:6379/0}"
AUDIO_CDN_URL="${AUDIO_CDN_URL:-https://release.app.org/api/v1/speech/sample}"

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "Error: la variable de entorno DATABASE_URL es obligatoria." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "[1/4] Provisionando infraestructura del entorno '${NAMESPACE}' con Terraform..."
terraform -chdir="${SCRIPT_DIR}" init -input=false
terraform -chdir="${SCRIPT_DIR}" apply -auto-approve -input=false \
  -var="namespace=${NAMESPACE}"

echo "[2/4] Creando/actualizando secreto 'app-release-secrets' en namespace '${NAMESPACE}'..."
kubectl create secret generic app-release-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal="DATABASE_URL=${DATABASE_URL}" \
  --from-literal="REDIS_URL=${REDIS_URL}" \
  --from-literal="AUDIO_CDN_URL=${AUDIO_CDN_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/4] Desplegando 'app-release' (${IMAGE_REPOSITORY}:${IMAGE_TAG}) mediante Helm..."
cd "${REPO_ROOT}"
helm upgrade --install app-release ./deploy/helm \
  --namespace "${NAMESPACE}" \
  --values ./deploy/helm/values-release.yaml \
  --set "image.repository=${IMAGE_REPOSITORY}" \
  --set "image.tag=${IMAGE_TAG}" \
  --atomic \
  --wait \
  --timeout 5m0s

echo "[4/4] Verificando disponibilidad del Deployment en '${NAMESPACE}'..."
kubectl rollout status deployment/app-release --namespace "${NAMESPACE}" --timeout=120s

echo "Entorno de liberación '${NAMESPACE}' provisionado y desplegado correctamente."
