#!/bin/bash
###############################################################################
# deploy_demo_app.sh
#
# Deploy Inference Design Planner into the participant's own namespace
# with MLflow tracing pre-configured.
#
# Multi-user workshop design:
#   - Namespace defaults to the logged-in OpenShift username (user1..userN)
#   - Routes use OpenShift auto-generated hosts (<route>-<ns>.<apps domain>),
#     so every participant gets unique URLs without cluster-level permissions
#   - Each participant gets a dedicated database (inference_planner_<ns>)
#     on the shared PostgreSQL in redhat-ods-applications
#
# Prerequisites:
#   - oc login completed as the workshop user (e.g. user7)
#   - The user's namespace already exists and the user has admin on it
#   - field-source-enable-all-features-35.sh already run (MLflow server; the per-user
#     mlflow-client-env ConfigMap is created by this script if missing)
#   - field-source-setup-maas-35.sh already run (PostgreSQL in redhat-ods-applications)
#   - Container images already pushed to registry
#
# Usage:
#   bash deploy_demo_app.sh <LLM_BASE_URL> <LLM_API_KEY> <LLM_MODEL>
#
# Example:
#   bash deploy_demo_app.sh \
#     https://qwen3-direct.apps.cluster.example.com/v1 \
#     not-needed \
#     qwen3-235b-a22b
#
# Options:
#   --namespace=<NS>    Target namespace (default: derived from `oc whoami`)
#
# Environment overrides:
#   PLANNER_BACKEND_IMAGE   (default: quay.io/rh-ee-hyochoi/inference-planner-backend:latest)
#   PLANNER_FRONTEND_IMAGE  (default: quay.io/rh-ee-hyochoi/inference-planner-frontend:latest)
#   MLFLOW_TRACKING_URI     (default: https://mlflow.redhat-ods-applications.svc:8443/mlflow)
#   MLFLOW_TRACKING_INSECURE_TLS (default: true)
#   MLFLOW_VERIFY_SSL       (default: false)
###############################################################################
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

###############################################################################
# Defaults
###############################################################################
NS=""
PG_NS="redhat-ods-applications"
PLANNER_BACKEND_IMAGE="${PLANNER_BACKEND_IMAGE:-quay.io/rh-ee-hyochoi/inference-planner-backend:latest}"
PLANNER_FRONTEND_IMAGE="${PLANNER_FRONTEND_IMAGE:-quay.io/rh-ee-hyochoi/inference-planner-frontend:latest}"
MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI:-https://mlflow.redhat-ods-applications.svc:8443/mlflow}"
MLFLOW_TRACKING_INSECURE_TLS="${MLFLOW_TRACKING_INSECURE_TLS:-true}"
MLFLOW_VERIFY_SSL="${MLFLOW_VERIFY_SSL:-false}"
USAGE="Usage: $0 <LLM_BASE_URL> <LLM_API_KEY> <LLM_MODEL> [--namespace=<NS>]"

###############################################################################
# Parse arguments
###############################################################################
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --namespace=*) NS="${arg#*=}" ;;
        -h|--help) echo "$USAGE"; exit 0 ;;
        --*) error "Unknown option: $arg"; exit 1 ;;
        *)   POSITIONAL+=("$arg") ;;
    esac
done

if [ ${#POSITIONAL[@]} -ne 3 ]; then
    echo "$USAGE"
    exit 1
fi

LLM_BASE_URL="${POSITIONAL[0]}"
LLM_API_KEY="${POSITIONAL[1]}"
LLM_MODEL="${POSITIONAL[2]}"

# Normalize LLM_BASE_URL: remove trailing slash to avoid double-slash in API paths
LLM_BASE_URL="${LLM_BASE_URL%/}"
# The backend uses an OpenAI-compatible client, which expects the base URL to
# include the API version (e.g. https://maas.apps.<cluster>/v1). Append /v1 if missing.
case "$LLM_BASE_URL" in
    */v1) ;;
    *) LLM_BASE_URL="${LLM_BASE_URL}/v1" ;;
esac

###############################################################################
# Resolve user + namespace
###############################################################################
OC_USER=$(oc whoami 2>/dev/null) || { error "oc login required"; exit 1; }

NS_SOURCE="--namespace flag"
if [ -z "$NS" ]; then
    NS_SOURCE="derived from oc whoami"
    case "$OC_USER" in
        kube:admin|system:*)
            error "Logged in as '$OC_USER' — cannot derive a workshop namespace."
            error "Log in as your workshop user (e.g. user1) or pass --namespace=<NS>."
            exit 1 ;;
    esac
    # Sanitize to a valid namespace name (lowercase, alphanumerics and '-')
    NS=$(echo "$OC_USER" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/^-*//' -e 's/-*$//')
fi

echo "=============================================="
echo " Deploy Inference Design Planner"
echo "   with MLflow Tracing"
echo "=============================================="
info "User      : $OC_USER"
info "Namespace : $NS ($NS_SOURCE)"
info "LLM URL   : $LLM_BASE_URL"
info "LLM Model : $LLM_MODEL"
echo ""

# Namespace must already exist (pre-created by workshop admin)
if ! oc get project "$NS" &>/dev/null; then
    error "Namespace '$NS' not found or not accessible by '$OC_USER'."
    error "Ask the workshop admin to create it, or pass --namespace=<NS>."
    exit 1
fi

# NetworkPolicy labels (allow cross-namespace access to PostgreSQL, MLflow, etc.)
# Namespace admins usually cannot label namespaces, so this is best-effort;
# the workshop admin should pre-label user namespaces.
oc label namespace "$NS" opendatahub.io/dashboard=true --overwrite &>/dev/null || true
oc label namespace "$NS" opendatahub.io/generated-namespace=true --overwrite &>/dev/null || true
NS_LABELS=$(oc get project "$NS" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)
if ! echo "$NS_LABELS" | grep -q 'opendatahub.io/dashboard'; then
    warn "Namespace '$NS' is missing label opendatahub.io/dashboard=true"
    warn "Cross-namespace access to PostgreSQL/MLflow may be blocked by NetworkPolicy"
fi

# MLflow client ConfigMap: points the backend at the shared MLflow server.
# Contents are identical for every user (isolation comes from MLFLOW_WORKSPACE,
# the per-namespace SA token and RoleBinding), so create it if missing.
# An existing ConfigMap (e.g. customised by an admin) is left untouched.
MLFLOW_AVAILABLE=false
if oc get configmap mlflow-client-env -n "$NS" &>/dev/null; then
    success "MLflow client ConfigMap found ✓"
    MLFLOW_AVAILABLE=true
else
    info "Creating MLflow client ConfigMap in $NS..."
    if oc apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mlflow-client-env
  namespace: ${NS}
data:
  MLFLOW_TRACKING_URI: "${MLFLOW_TRACKING_URI}"
  MLFLOW_TRACKING_INSECURE_TLS: "${MLFLOW_TRACKING_INSECURE_TLS}"
  VERIFY_SSL: "${MLFLOW_VERIFY_SSL}"
EOF
    then
        success "MLflow client ConfigMap created ✓"
        MLFLOW_AVAILABLE=true
    else
        warn "Could not create ConfigMap mlflow-client-env in $NS — MLflow tracing will be disabled"
    fi
fi
echo ""

###############################################################################
# Step 1: Routes
#   Created first without spec.host so OpenShift assigns a unique host per
#   namespace (<route>-<ns>.<apps domain>). The resolved hosts are needed
#   for CORS and the frontend's API URL. No cluster-level read access needed.
###############################################################################
info "=== Step 1/6: Routes ==="

oc apply -n "$NS" -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: inference-planner-api
  namespace: ${NS}
  labels:
    app: planner-backend
spec:
  to:
    kind: Service
    name: planner-backend
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: inference-planner
  namespace: ${NS}
  labels:
    app: planner-frontend
spec:
  to:
    kind: Service
    name: planner-frontend
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

get_route_host() {
    local name="$1" host="" wait=0
    while [ $wait -lt 30 ]; do
        host=$(oc get route "$name" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
        [ -n "$host" ] && { echo "$host"; return 0; }
        sleep 2; wait=$((wait + 2))
    done
    return 1
}

API_HOST=$(get_route_host inference-planner-api) || { error "Route inference-planner-api has no host"; exit 1; }
FE_HOST=$(get_route_host inference-planner)      || { error "Route inference-planner has no host"; exit 1; }
PLANNER_API="https://${API_HOST}"
PLANNER_URL="https://${FE_HOST}"
success "Frontend route: $PLANNER_URL"
success "Backend route : $PLANNER_API"
echo ""

###############################################################################
# Step 2: Per-user database on existing PostgreSQL
#   The POC PostgreSQL lives in redhat-ods-applications (deployed by
#   field-source-setup-maas-35.sh). Each participant gets their own database so
#   migrations and data don't collide.
###############################################################################
info "=== Step 2/6: PostgreSQL (dedicated database on shared server) ==="

# Fail early with a clear message if the user can't reach the shared PostgreSQL
if ! oc auth can-i get deployments -n "$PG_NS" &>/dev/null || \
   ! oc auth can-i create pods/exec -n "$PG_NS" &>/dev/null; then
    error "User '$OC_USER' lacks access to $PG_NS (needs get deployments + pods/exec)."
    error "Ask the workshop admin to grant access, or pre-provision the database."
    exit 1
fi

if ! oc get deployment postgres -n "$PG_NS" &>/dev/null; then
    error "PostgreSQL not found in $PG_NS"
    error "Run field-source-setup-maas-35.sh first to deploy PostgreSQL"
    exit 1
fi

# Check PostgreSQL is healthy
PG_READY=$(oc get pods -n "$PG_NS" -l app=postgres \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
if [ "$PG_READY" != "true" ]; then
    warn "PostgreSQL pod not ready — waiting up to 60s..."
    WAIT=0
    while [ $WAIT -lt 60 ]; do
        PG_READY=$(oc get pods -n "$PG_NS" -l app=postgres \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
        [ "$PG_READY" = "true" ] && break
        sleep 5; WAIT=$((WAIT + 5))
    done
    [ "$PG_READY" != "true" ] && { error "PostgreSQL not ready"; exit 1; }
fi
success "PostgreSQL running in $PG_NS ✓"

# Read credentials from the existing deployment
PG_USER=$(oc get deployment postgres -n "$PG_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_USER")].value}' 2>/dev/null)
PG_PASSWORD=$(oc get deployment postgres -n "$PG_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].value}' 2>/dev/null)

[ -z "$PG_USER" ] && { error "Cannot read PostgreSQL user from deployment"; exit 1; }
[ -z "$PG_PASSWORD" ] && { error "Cannot read PostgreSQL password from deployment"; exit 1; }

# Per-user database name (e.g. user7 -> inference_planner_user7)
PLANNER_DB="inference_planner_${NS//-/_}"
PG_POD=$(oc get pods -n "$PG_NS" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

db_exists() {
    oc exec "$PG_POD" -n "$PG_NS" -- \
        psql -U "$PG_USER" -d "$PG_USER" -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${PLANNER_DB}'" 2>/dev/null || true
}

info "Ensuring database '$PLANNER_DB' exists..."
if [ "$(db_exists)" = "1" ]; then
    success "Database '$PLANNER_DB' already exists ✓"
else
    # The app role (e.g. 'maas') usually lacks CREATEDB, so create the database
    # as the 'postgres' superuser over the pod's local socket, owned by the app role.
    CREATE_ERR=$(oc exec "$PG_POD" -n "$PG_NS" -- \
        psql -U postgres -d postgres \
        -c "CREATE DATABASE \"${PLANNER_DB}\" OWNER \"${PG_USER}\"" 2>&1 >/dev/null) || true
    # Re-check (another run may have created it concurrently)
    if [ "$(db_exists)" = "1" ]; then
        success "Database '$PLANNER_DB' created ✓"
    else
        error "Could not create database '$PLANNER_DB'"
        [ -n "$CREATE_ERR" ] && error "PostgreSQL said: $CREATE_ERR"
        exit 1
    fi
fi
TARGET_DB="$PLANNER_DB"

# Build cross-namespace DB URL (FQDN required for <user ns> → redhat-ods-applications)
# URL-encode password (pure bash)
ENCODED_PW=""
for (( i=0; i<${#PG_PASSWORD}; i++ )); do
    _c="${PG_PASSWORD:$i:1}"
    case "$_c" in
        [a-zA-Z0-9._~-]) ENCODED_PW+="$_c" ;;
        *) ENCODED_PW+=$(printf '%%%02X' "'$_c") ;;
    esac
done
PG_FQDN="postgres.${PG_NS}.svc.cluster.local"

DB_URL_ASYNC="postgresql+asyncpg://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/${TARGET_DB}"
DB_URL_SYNC="postgresql://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/${TARGET_DB}"

info "DB: ${PG_USER}@${PG_FQDN}:5432/${TARGET_DB}"
echo ""

###############################################################################
# Step 3: ConfigMap + Secret + MLflow auth
###############################################################################
info "=== Step 3/6: Configuration ==="

oc apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: planner-config
  namespace: ${NS}
data:
  APP_ENV: "production"
  APP_LOG_LEVEL: "INFO"
  APP_CORS_ORIGINS: "${PLANNER_URL}"
  LLM_MODEL: "${LLM_MODEL}"
  LLM_MODEL_NAME: "${LLM_MODEL}"
  MLFLOW_EXPERIMENT_NAME: "inference-design-planner"
  MLFLOW_WORKSPACE: "${NS}"
  PROMETHEUS_ENABLED: "true"
  HF_HOME: "/tmp/hf_cache"
---
apiVersion: v1
kind: Secret
metadata:
  name: planner-secrets
  namespace: ${NS}
type: Opaque
stringData:
  # LLM_* are read by the backend settings (backend/config.py);
  # OPENAI_* kept for compatibility with older images / OpenAI SDK defaults.
  LLM_BASE_URL: "${LLM_BASE_URL}"
  LLM_API_KEY: "${LLM_API_KEY}"
  OPENAI_BASE_URL: "${LLM_BASE_URL}"
  OPENAI_API_KEY: "${LLM_API_KEY}"
  DATABASE_URL: "${DB_URL_ASYNC}"
  DATABASE_URL_SYNC: "${DB_URL_SYNC}"
EOF
success "Config + secrets created"

# MLflow RBAC + SA token must exist BEFORE the backend Deployment references them
if [ "$MLFLOW_AVAILABLE" = true ]; then
    if oc create rolebinding planner-mlflow-integration \
        --clusterrole=mlflow-operator-mlflow-integration \
        --serviceaccount="${NS}:default" \
        -n "$NS" --dry-run=client -o yaml 2>/dev/null | oc apply -f - &>/dev/null; then
        success "MLflow RBAC configured"
    else
        warn "Could not create rolebinding planner-mlflow-integration (insufficient permissions?)"
        warn "MLflow tracing may fail until the workshop admin creates it"
    fi

    # Non-expiring SA token secret for MLflow authentication
    if ! oc get secret mlflow-sa-token -n "$NS" &>/dev/null; then
        oc apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mlflow-sa-token
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: default
type: kubernetes.io/service-account-token
EOF
        success "MLflow SA token secret created"
    fi
fi
echo ""

###############################################################################
# Step 4: DB Migration
###############################################################################
info "=== Step 4/6: DB Migration ==="

oc delete job planner-db-migrate -n "$NS" 2>/dev/null || true
oc apply -n "$NS" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: planner-db-migrate
  namespace: ${NS}
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: ${PLANNER_BACKEND_IMAGE}
          command: ["alembic", "upgrade", "head"]
          envFrom:
            - secretRef:
                name: planner-secrets
            - configMapRef:
                name: planner-config
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
EOF

JOB_STATUS=""
WAIT=0
while [ $WAIT -lt 120 ]; do
    JOB_STATUS=$(oc get job planner-db-migrate -n "$NS" \
        -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    [ "$JOB_STATUS" = "1" ] && { success "DB migration complete ✓"; break; }
    JOB_FAILED=$(oc get job planner-db-migrate -n "$NS" \
        -o jsonpath='{.status.failed}' 2>/dev/null || true)
    [ "${JOB_FAILED:-0}" -ge 3 ] && { warn "DB migration failed (check: oc logs job/planner-db-migrate -n $NS)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done
[ "${JOB_STATUS:-}" != "1" ] && warn "DB migration not confirmed — backend may handle it at startup"
echo ""

###############################################################################
# Step 5: Backend + Frontend
###############################################################################
info "=== Step 5/6: Backend + Frontend ==="

# Only wire MLflow env into the backend when its ConfigMap/Secret exist;
# otherwise the pod would be stuck in CreateContainerConfigError.
MLFLOW_ENVFROM=""
MLFLOW_ENV=""
if [ "$MLFLOW_AVAILABLE" = true ]; then
    MLFLOW_ENVFROM="
            - configMapRef:
                name: mlflow-client-env"
    MLFLOW_ENV="
          env:
            - name: MLFLOW_TRACKING_TOKEN
              valueFrom:
                secretKeyRef:
                  name: mlflow-sa-token
                  key: token"
fi

# Pods only read envFrom ConfigMaps/Secrets at startup. Stamp a hash of the
# configuration onto the pod template so a re-run with changed values (e.g. a
# new LLM URL/key/model) triggers a rollout instead of leaving stale pods.
CONFIG_HASH=$(printf '%s|%s|%s|%s|%s|%s' "$LLM_BASE_URL" "$LLM_API_KEY" "$LLM_MODEL" \
    "$DB_URL_ASYNC" "$PLANNER_URL" "$MLFLOW_AVAILABLE" | cksum | awk '{print $1}')

oc apply -n "$NS" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: planner-backend
  namespace: ${NS}
  labels:
    app: planner-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: planner-backend
  template:
    metadata:
      labels:
        app: planner-backend
      annotations:
        planner/config-hash: "${CONFIG_HASH}"
    spec:
      containers:
        - name: backend
          image: ${PLANNER_BACKEND_IMAGE}
          ports:
            - containerPort: 8000
              name: http
          envFrom:
            - configMapRef:
                name: planner-config
            - secretRef:
                name: planner-secrets${MLFLOW_ENVFROM}${MLFLOW_ENV}
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /api/v1/health
              port: 8000
            initialDelaySeconds: 120
            periodSeconds: 30
            failureThreshold: 5
          readinessProbe:
            httpGet:
              path: /api/v1/health
              port: 8000
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 10
---
apiVersion: v1
kind: Service
metadata:
  name: planner-backend
  namespace: ${NS}
  labels:
    app: planner-backend
spec:
  selector:
    app: planner-backend
  ports:
    - name: http
      port: 8000
      targetPort: 8000
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: planner-frontend
  namespace: ${NS}
  labels:
    app: planner-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: planner-frontend
  template:
    metadata:
      labels:
        app: planner-frontend
    spec:
      containers:
        - name: frontend
          image: ${PLANNER_FRONTEND_IMAGE}
          ports:
            - containerPort: 3000
              name: http
          env:
            - name: NEXT_PUBLIC_API_URL
              value: "${PLANNER_API}"
            - name: NEXT_PUBLIC_AGENT_URL
              value: "${PLANNER_API}/agent"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: planner-frontend
  namespace: ${NS}
  labels:
    app: planner-frontend
spec:
  selector:
    app: planner-frontend
  ports:
    - name: http
      port: 3000
      targetPort: 3000
  type: ClusterIP
EOF

success "Backend + Frontend applied"
echo ""

###############################################################################
# Step 6: Verify
###############################################################################
info "=== Step 6/6: Verify ==="

oc rollout status deployment/planner-backend -n "$NS" --timeout=600s 2>/dev/null || \
    warn "Backend rollout timeout (check: oc describe pod -l app=planner-backend -n $NS)"
oc rollout status deployment/planner-frontend -n "$NS" --timeout=300s 2>/dev/null || \
    warn "Frontend rollout timeout (check: oc describe pod -l app=planner-frontend -n $NS)"

echo ""
BE_READY=$(oc get deployment planner-backend -n "$NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
FE_READY=$(oc get deployment planner-frontend -n "$NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

[ "${BE_READY:-0}" -ge 1 ] && echo "  ✅ Backend   : $PLANNER_API" || \
    echo "  ⬚  Backend   : $PLANNER_API (starting...)"
[ "${FE_READY:-0}" -ge 1 ] && echo "  ✅ Frontend  : $PLANNER_URL" || \
    echo "  ⬚  Frontend  : $PLANNER_URL (starting...)"
[ "$MLFLOW_AVAILABLE" = true ] && \
    echo "  ✅ MLflow    : enabled (workspace: $NS, experiment: inference-design-planner)" || \
    echo "  ⬚  MLflow    : disabled (mlflow-client-env could not be created)"
echo "  ✅ Database  : ${TARGET_DB}@${PG_FQDN}"
echo "  ✅ Namespace : $NS"

echo ""
info "LLM:"
echo "  URL   : $LLM_BASE_URL"
echo "  Model : $LLM_MODEL"

echo ""
echo "=============================================="
success "Done!"
echo ""
echo "  MLflow UI:"
echo "    Dashboard → Experiments → inference-design-planner"
echo ""
echo "  If pods show ⬚, wait a minute and check:"
echo "    oc get pods -n $NS"
echo "=============================================="
