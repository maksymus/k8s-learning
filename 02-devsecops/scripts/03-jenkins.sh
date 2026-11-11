#!/usr/bin/env bash
# Adds the signing credentials to Jenkins and lets build pods trust the registry's private CA.
source "$(dirname "$0")/lib.sh"

JENKINS_CHART=5.9.69 # the version project 1 installed; plugins on the PVC were built for it

kubectl -n jenkins get secret cosign-credentials >/dev/null 2>&1 || { echo "Secret cosign-credentials missing. Run 02 first."; exit 1; }

log "Publishing the registry CA for build pods"
kubectl -n jenkins create configmap registry-ca --from-file=ca.crt="$KEYS/tls/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# BuildKit reads one config file, so write it whole: the CA, plus the Docker Hub mirror on a remote host.
TOML=$(printf '[registry."%s"]\n  ca = ["/home/user/.config/buildkit/ca.crt"]\n' "$REGISTRY")
if [ -n "$REMOTE_HOST" ]; then
  GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  TOML+=$(printf '\n[registry."docker.io"]\n  mirrors = ["%s:5010"]\n[registry."%s:5010"]\n  http = true\n' "$GW" "$GW")
  # Trivy's database is a long download too, so it comes through the ghcr.io cache.
  kubectl -n jenkins create configmap ci-env \
    --from-literal=TRIVY_DB_REPOSITORY="$GW:5013/aquasecurity/trivy-db:2" --from-literal=TRIVY_INSECURE=true \
    --dry-run=client -o yaml | kubectl apply -f -
fi
kubectl -n jenkins create configmap buildkitd-config --from-literal=buildkitd.toml="$TOML" \
  --from-file=ca.crt="$KEYS/tls/ca.crt" --dry-run=client -o yaml | kubectl apply -f -

log "Upgrading Jenkins with the project 2 overrides"
helm_repo jenkins https://charts.jenkins.io
helm upgrade --install jenkins jenkins/jenkins -n jenkins --version "$JENKINS_CHART" \
  -f "$ROOT/platform/jenkins-values.yaml" -f "$LAB/platform/jenkins-overrides.yaml" \
  --set controller.admin.password="$JENKINS_PASS"

# A StatefulSet won't replace a pod that is already unhealthy, so a stuck one would block the rollout.
if [ "$(kubectl -n jenkins get pod jenkins-0 -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}' 2>/dev/null)" != true ]; then
  kubectl -n jenkins delete pod jenkins-0 --ignore-not-found
fi
kubectl -n jenkins rollout status statefulset/jenkins --timeout=10m
