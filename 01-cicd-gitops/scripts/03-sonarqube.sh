#!/usr/bin/env bash
# SonarQube: static analysis + coverage, enforced by the quality gate.
source "$(dirname "$0")/lib.sh"

log "Installing SonarQube (first start takes 3-5 minutes)"
helm_repo sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm upgrade --install sonarqube sonarqube/sonarqube -n sonarqube --create-namespace \
  -f "$ROOT/platform/sonarqube-values.yaml" --wait --timeout 15m

port_forward sonarqube sonarqube-sonarqube 19000 9000
S=http://localhost:19000

log "Waiting for SonarQube to report UP"
until [ "$(curl -s "$S/api/system/status" | jq -r .status 2>/dev/null)" = UP ]; do sleep 5; done

log "Setting the admin password"
if [ "$(curl -s -u "admin:$SONAR_PASS" "$S/api/authentication/validate" | jq -r .valid)" != true ]; then
  curl -sf -u admin:admin -X POST "$S/api/users/change_password" \
    --data-urlencode login=admin --data-urlencode previousPassword=admin \
    --data-urlencode "password=$SONAR_PASS"
fi

log "Creating an analysis token for Jenkins"
curl -s -u "admin:$SONAR_PASS" -X POST "$S/api/user_tokens/revoke" -d name=jenkins >/dev/null || true
TOKEN=$(curl -sf -u "admin:$SONAR_PASS" -X POST "$S/api/user_tokens/generate" \
  -d name=jenkins -d type=GLOBAL_ANALYSIS_TOKEN | jq -r .token)

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins create secret generic sonar-credentials --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
