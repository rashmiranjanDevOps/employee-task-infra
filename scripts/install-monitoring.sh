#!/usr/bin/env bash
#
# install-monitoring.sh — installs an in-cluster observability stack
# (Prometheus + Alertmanager + Grafana) for one environment.
#
# This deliberately REUSES the exact same alert rules, Alertmanager
# routing/Slack config, and Grafana dashboard/datasource already defined in
# employee-task-app/monitoring/ (the local Docker Compose stack) — so
# there's exactly one place these are authored, not two that can quietly
# drift apart (see ARCHITECTURE.md's naming/drift section).
#
# Prometheus scrapes the real backend Service by its in-cluster DNS name
# (employee-task-<env>-backend.employee-task-<env>.svc.cluster.local:5000),
# using job_name "employee-task-backend" — the same job name the existing
# alert.rules.yml and the Grafana dashboard already expect. No ServiceMonitor
# CRD, no change to the app's Helm chart.
#
# Run once per environment, any time after that environment's app is
# already deployed (needs the backend Service to exist). Idempotent.
#
# Usage:
#   ./install-monitoring.sh <dev|prod> <path-to-employee-task-app-repo>
# Example:
#   ./install-monitoring.sh dev ../employee-task-app
#
# Slack is optional: export SLACK_WEBHOOK_URL before running to wire up
# Alertmanager -> Slack. If unset, Alertmanager runs with an empty webhook
# (no Slack messages, nothing breaks) — same "optional, no-op if unset"
# convention as notify-slack.sh.

set -euo pipefail

ENVIRONMENT="${1:?Usage: $0 <dev|prod> <path-to-employee-task-app-repo>}"
APP_REPO="${2:?Usage: $0 <dev|prod> <path-to-employee-task-app-repo>}"
NAMESPACE="monitoring-${ENVIRONMENT}"
APP_NAMESPACE="employee-task-${ENVIRONMENT}"
BACKEND_SVC="employee-task-${ENVIRONMENT}-backend"
APP_DOMAIN="rashmidevops.xyz"
GRAFANA_HOSTNAME="grafana-${ENVIRONMENT}.${APP_DOMAIN}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOBAL_TF_DIR="${REPO_ROOT}/terraform/global"
MON_DIR="${APP_REPO}/monitoring"

if [[ ! -d "${MON_DIR}" ]]; then
  echo "ERROR: ${MON_DIR} not found — check the path to employee-task-app." >&2
  exit 1
fi

# --- verify: the backend Service this whole script depends on actually
#     exists before we build anything on top of it ---
if ! kubectl -n "${APP_NAMESPACE}" get service "${BACKEND_SVC}" >/dev/null 2>&1; then
  echo "ERROR: Service ${BACKEND_SVC} not found in namespace ${APP_NAMESPACE}." >&2
  echo "       Deploy the app to ${ENVIRONMENT} first (see EXECUTION-GUIDE.md Phase 7-8)." >&2
  exit 1
fi
echo "OK: found backend Service ${BACKEND_SVC}.${APP_NAMESPACE}."

echo
echo "=================================================="
echo " Phase 1: Namespace + Slack webhook secret"
echo "=================================================="

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  kubectl -n "${NAMESPACE}" create secret generic alertmanager-slack \
    --from-literal=slack_url="${SLACK_WEBHOOK_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "OK: alertmanager-slack secret created from \$SLACK_WEBHOOK_URL."
else
  kubectl -n "${NAMESPACE}" create secret generic alertmanager-slack \
    --from-literal=slack_url="" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "WARNING: SLACK_WEBHOOK_URL not set — Alertmanager will run with no Slack webhook."
fi

echo
echo "=================================================="
echo " Phase 2: Installing Alertmanager"
echo "=================================================="

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# The chart's values schema requires `config` to be a nested YAML object,
# not a raw string — --set-file always produces a string, which fails
# schema validation ("got string, want object"). Building a small values
# file that indents alertmanager.yml's contents under `config:` gives Helm
# a real object instead.
ALERTMANAGER_VALUES="$(mktemp)"
{
  echo "config:"
  sed 's/^/  /' "${MON_DIR}/prometheus/alertmanager.yml"
} > "${ALERTMANAGER_VALUES}"

helm upgrade --install alertmanager prometheus-community/alertmanager \
  --namespace "${NAMESPACE}" \
  -f "${ALERTMANAGER_VALUES}" \
  --set persistence.enabled=false \
  --set extraSecretMounts[0].name=slack-secret \
  --set extraSecretMounts[0].secretName=alertmanager-slack \
  --set extraSecretMounts[0].mountPath=/etc/alertmanager/secrets \
  --wait --timeout 5m

rm -f "${ALERTMANAGER_VALUES}"

kubectl -n "${NAMESPACE}" rollout status statefulset/alertmanager --timeout=120s
echo "OK: Alertmanager is Running."

echo
echo "=================================================="
echo " Phase 3: Installing Prometheus (scraping the real backend Service)"
echo "=================================================="

# Same issue as Alertmanager's config above: serverFiles."alerting_rules.yml"
# must be a nested YAML object, not a raw string from --set-file. Build a
# values file that nests alert.rules.yml's own content (already valid YAML)
# under the right key.
PROMETHEUS_VALUES="$(mktemp)"
{
  echo "serverFiles:"
  echo "  alerting_rules.yml:"
  sed 's/^/    /' "${MON_DIR}/prometheus/alert.rules.yml"
} > "${PROMETHEUS_VALUES}"

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace "${NAMESPACE}" \
  --set alertmanager.enabled=false \
  --set server.persistentVolume.enabled=false \
  --set server.alertmanagers[0].static_configs[0].targets[0]="alertmanager.${NAMESPACE}.svc:9093" \
  -f "${PROMETHEUS_VALUES}" \
  --set-string extraScrapeConfigs="- job_name: employee-task-backend
  metrics_path: /metrics
  static_configs:
    - targets: ['${BACKEND_SVC}.${APP_NAMESPACE}.svc.cluster.local:5000']" \
  --wait --timeout 5m

rm -f "${PROMETHEUS_VALUES}"

kubectl -n "${NAMESPACE}" rollout status deployment/prometheus-server --timeout=180s
echo "OK: Prometheus is Running."

echo
echo "=================================================="
echo " Phase 4: Installing Grafana (existing dashboard + datasource)"
echo "=================================================="

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl -n "${NAMESPACE}" create configmap grafana-dashboard-app-overview \
  --from-file="${MON_DIR}/grafana/dashboards/application-overview.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" label configmap grafana-dashboard-app-overview grafana_dashboard=1 --overwrite

helm upgrade --install grafana grafana/grafana \
  --namespace "${NAMESPACE}" \
  --set adminUser=admin \
  --set persistence.enabled=false \
  --set sidecar.dashboards.enabled=true \
  --set sidecar.dashboards.label=grafana_dashboard \
  --set datasources."datasources\.yaml".apiVersion=1 \
  --set datasources."datasources\.yaml".datasources[0].name=Prometheus \
  --set datasources."datasources\.yaml".datasources[0].type=prometheus \
  --set datasources."datasources\.yaml".datasources[0].url="http://prometheus-server.${NAMESPACE}.svc" \
  --set datasources."datasources\.yaml".datasources[0].isDefault=true \
  --wait --timeout 5m

kubectl -n "${NAMESPACE}" rollout status deployment/grafana --timeout=180s
echo "OK: Grafana is Running."
GRAFANA_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)

echo
echo "=================================================="
echo " Phase 5: Exposing Grafana (Ingress + DNS)"
echo "=================================================="

# Same wildcard cert already used for the app + ArgoCD — no new ACM
# resource or DNS validation needed since it covers *.rashmidevops.xyz.
ACM_CERT_ARN=$(terraform -chdir="${GLOBAL_TF_DIR}" output -raw acm_certificate_arn)

if [[ -z "${ACM_CERT_ARN}" ]]; then
  echo "ERROR: acm_certificate_arn is empty. Run 'terraform apply' in ${GLOBAL_TF_DIR} first." >&2
  exit 1
fi

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: ${ACM_CERT_ARN}
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  ingressClassName: alb
  rules:
    - host: ${GRAFANA_HOSTNAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 80
EOF

echo "--> Waiting for the ALB to be provisioned (this can take 2-3 minutes)..."
for i in $(seq 1 30); do
  ALB_HOSTNAME=$(kubectl -n "${NAMESPACE}" get ingress grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "${ALB_HOSTNAME}" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "${ALB_HOSTNAME}" ]]; then
  echo "ERROR: the Grafana Ingress has no ADDRESS after 5 minutes." >&2
  echo "       Check the controller's logs:" >&2
  echo "       kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50" >&2
  exit 1
fi
echo "OK: ALB provisioned — ${ALB_HOSTNAME}"

"${REPO_ROOT}/scripts/update-dns.sh" upsert "${GRAFANA_HOSTNAME}" "${ALB_HOSTNAME}"

echo
echo "=================================================="
echo " Monitoring installed successfully for ${ENVIRONMENT}"
echo "=================================================="
echo
echo "Grafana UI:             https://${GRAFANA_HOSTNAME}"
echo "Grafana admin password: ${GRAFANA_PASSWORD}"
echo
echo "Verify Prometheus is actually scraping the real backend:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/prometheus-server 9090:80"
echo "  then open http://localhost:9090/targets and confirm the"
echo "  employee-task-backend job shows State: UP"