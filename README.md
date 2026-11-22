# `app-cicd` — Plataforma de Aprendizaje de Lenguas Maternas e Indígenas

Repositorio base de ingeniería DevOps/SRE, infraestructura como código (IaC), pruebas automatizadas y aplicación FastAPI para la **Plataforma de Aprendizaje de Lenguas Maternas e Indígenas** orientada a micro-lecciones gamificadas en **Náhuatl**, **Maya Yucateco**, **Zapoteco**, **Mixteco** y **Tsotsil** sobre Kubernetes.

---

## Arquitectura de Microservicios

La plataforma `app` opera sobre un clúster Kubernetes (`app-cluster`) organizado en microservicios desacoplados con soporte estricto **UTF-8** (preservación de saltillo `ꞌ`, tonos y macrones `ā, ē, ī, ō`):

```text
                       HTTPS / TLS (cert-manager)
                release.app.org  |  api.app.org
                                 v
                     +-----------------------+
                     |   Ingress NGINX       |
                     +-----------------------+
                                 |
                                 v
                     +-----------------------+
                     |       gateway         |  Enrutamiento, OIDC, rate-limiting
                     +-----------------------+
                       /         |         \
                      v          v          v
           +-----------+   +-----------+   +-----------+
           |  lessons  |   |  speech   |   |  lexicon  |
           +-----------+   +-----------+   +-----------+
                 |               |               |
                 v               v               v
         [Redis / PostgreSQL] [Audio WAV/CDN] [Diccionario Dialectal]
```

| Microservicio | Responsabilidad Principal | Endpoints / Capacidades Base en `src/main.py` |
| :--- | :--- | :--- |
| **`gateway`** | Punto de entrada unificado, sondas de salud Kubernetes, encabezados de seguridad y control de tráfico TLS. | `GET /healthz`, `GET /ready` |
| **`lessons`** | Entrega de micro-lecciones gamificadas, vocabulario, ejercicios y XP con soporte UTF-8 íntegro para saltillo y diacríticos. | `GET /api/v1/lessons/nahuatl/unidad-1` |
| **`speech`** | Distribución de muestras de audio nativo (`audio/wav`) y soporte a evaluación fonética con validación estricta de nombres de archivo. | `GET/HEAD /api/v1/speech/sample/{filename}` |
| **`lexicon`** | Diccionario comunitario multilingüe y gestión de variantes dialectales regionales (ver suite ReadySET en [`tests/release/test-cases-readyset.html`](tests/release/test-cases-readyset.html)). | Integrado en arquitectura y pruebas de aceptación |

---

## Flujo del Pipeline CI/CD (`.github/workflows/ci-cd-pipeline.yml`)

El pipeline se dispara en `push` y `pull_request` sobre la rama `main`, utiliza federación **OIDC** (`id-token: write`) sin credenciales de larga duración y control de `concurrency` por rama:

1. **`static-analysis`**:
   - Linter de código Python con `ruff check .`.
   - Análisis de calidad y deuda técnica con **SonarQube** (`SonarSource/sonarqube-scan-action`, configuración en `sonar-project.properties`).
   - Escaneo de vulnerabilidades, secretos y configuraciones inseguras con **Trivy** (`HIGH,CRITICAL`, `exit-code: '1'`, políticas en `.trivy.yaml`).
2. **`unit-tests`**:
   - Ejecución de `pytest --cov=src --cov-fail-under=85 tests/unit/` verificando contratos, sondas y codificación UTF-8.
3. **`build-and-sign`** *(solo en `push` a `main`)*:
   - Construcción multi-stage no-root con **Docker Buildx** (`Dockerfile`).
   - Publicación en `ghcr.io/<org>/app-cicd:<GITHUB_SHA>`.
   - Firma criptográfica **keyless OIDC** por digest usando **Sigstore Cosign** (`cosign sign --yes`).
4. **`deploy-release`** *(entorno `release`)*:
   - Autenticación OIDC hacia AWS (`aws-actions/configure-aws-credentials`) y actualización de kubeconfig para `app-cluster`.
   - Ejecución de `./infra/release-env/provision_release.sh`: aplica Terraform (`namespace release`, `NetworkPolicy` de aislamiento y Redis Bitnami standalone), crea/actualiza `app-release-secrets` y despliega `app-release` vía Helm (`--atomic --wait --timeout 5m0s`).
5. **`release-verification`**:
   - Ejecución de `./tests/release/run_release_tests.sh`: Smoke Tests con reintentos sobre `https://release.app.org/healthz`, validación de contrato JSON y caracteres UTF-8 (`ꞌ`, `ō`, `ā`), verificación de audio `WAV` nativo y pruebas de carga con **k6** (`25 VUs / 45s`).
6. **`deploy-production`** *(entorno `production` con puerta de aprobación manual)*:
   - Autenticación OIDC hacia AWS, despliegue atómico de `app-prod` en namespace `prod` con `./deploy/deploy_production.sh` (HPA 6–30 réplicas, Ingress TLS `letsencrypt-prod` en `api.app.org`).
   - Espera **45 segundos** de estabilización y consulta la API de **Prometheus** sobre la tasa de errores HTTP 5xx en los últimos 2 minutos; si supera **`0.001` (0.1%)**, dispara automáticamente `helm rollback app-prod 0 --namespace prod --wait`.

---

## Acuerdos SLA / SLO y Umbrales de Calidad

| Indicador | Objetivo (SLO / Umbral) | Mecanismo de Verificación |
| :--- | :--- | :--- |
| **Disponibilidad del servicio** | `>= 99.95%` | Sondas `/healthz` y `/ready`, rolling updates sin caída (`maxUnavailable: 0`) |
| **Latencia de lecciones (P95)** | `<= 250 ms` | Umbral estricto en `tests/release/k6-load-test.js` (`p(95)<250`) |
| **Latencia de audio nativo (P95)** | `<= 850 ms` | Umbral etiquetado `endpoint:audio` en `k6-load-test.js` (`p(95)<850`) |
| **Tasa de errores HTTP 5xx** | `<= 0.1%` (`0.001`) | PromQL en `deploy/deploy_production.sh` con rollback automático |
| **Tasa de fallos en carga (k6)** | `< 1%` (`rate<0.01`) | `http_req_failed` en `k6-load-test.js` |
| **Cobertura de pruebas unitarias** | `>= 85%` | `pytest --cov=src --cov-fail-under=85` en Job 2 |
| **Vulnerabilidades `HIGH` / `CRITICAL`** | `0` toleradas | Trivy con `exit-code: '1'` en Job 1 |

---

## Configuración en GitHub (Secretos, Variables y Entornos)

Antes de ejecutar el pipeline completo en GitHub Actions, configura lo siguiente en **Settings > Environments** y **Settings > Secrets and variables > Actions**:

### 1. Entornos (`release` y `production`)
- **`release`**:
  - URL de despliegue: `https://release.app.org`
  - Sin aprobadores manuales obligatorios (despliegue continuo tras pruebas unitarias y firma).
- **`production`**:
  - URL de despliegue: `https://api.app.org`
  - Configurar **Required reviewers** (puerta de aprobación SRE/Product Owner antes de promover a producción).

### 2. Secretos y Variables Requeridos

| Nivel | Tipo | Nombre | Descripción |
| :--- | :--- | :--- | :--- |
| Repositorio | Variable | `AWS_REGION` | Región del clúster EKS `app-cluster` (por defecto `us-east-1`). |
| Repositorio | Secreto | `SONAR_TOKEN` | Token de autenticación para SonarQube / SonarCloud. |
| Repositorio | Secreto | `SONAR_HOST_URL` | URL base de la instancia de SonarQube. |
| Entorno `release` | Secreto | `AWS_ROLE_ARN_RELEASE` | ARN del rol IAM con confianza OIDC para desplegar en el namespace `release`. |
| Entorno `release` | Secreto | `RELEASE_DATABASE_URL` | Cadena de conexión PostgreSQL del entorno `release`. |
| Entorno `release` | Secreto | `RELEASE_REDIS_URL` | *(Opcional)* URL de Redis (por defecto `redis://redis-master.release.svc.cluster.local:6379/0`). |
| Entorno `release` | Secreto | `RELEASE_AUDIO_CDN_URL` | *(Opcional)* Base URL para muestras de audio en `release`. |
| Entorno `production` | Secreto | `AWS_ROLE_ARN_PROD` | ARN del rol IAM con confianza OIDC para desplegar en el namespace `prod`. |
| Entorno `production` | Secreto | `PROMETHEUS_URL` | URL de la API HTTP de Prometheus usada para validar la tasa de 5xx post-despliegue. |

---

## Comandos de Ejecución Local y Despliegue

### Desarrollo, Linting y Pruebas Unitarias
```bash
python -m venv .venv
source .venv/bin/activate  # En Windows PowerShell: .\.venv\Scripts\Activate.ps1

pip install -r requirements-dev.txt -r requirements-test.txt

# Linter con Ruff
ruff check .

# Pruebas unitarias y cobertura mínima del 85%
pytest --cov=src --cov-fail-under=85 --cov-report=term-missing tests/unit/

# Levantar API localmente
uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload
```

### Construcción de Contenedor
```bash
docker build -t app-cicd:local .
docker run --rm -p 8000:8000 app-cicd:local
```

### Provisionamiento y Pruebas de Liberación
```bash
export DATABASE_URL="postgresql://user:pass@db.release.internal:5432/app"
./infra/release-env/provision_release.sh "<IMAGE_SHA>"

BASE_URL="https://release.app.org" ./tests/release/run_release_tests.sh
```

### Despliegue a Producción y Verificación SLO
```bash
export PROMETHEUS_URL="http://prometheus-server.monitoring.svc.cluster.local:9090"
./deploy/deploy_production.sh "<IMAGE_SHA>"
```
