#!/usr/bin/env bash
# Jenkins: configured entirely by JCasC in platform/jenkins-values.yaml.
source "$(dirname "$0")/lib.sh"

for s in gitea-credentials sonar-credentials; do
  kubectl -n jenkins get secret "$s" >/dev/null 2>&1 || { echo "Secret $s missing. Run 02 and 03 first."; exit 1; }
done

log "Installing Jenkins (plugin downloads take a few minutes)"
helm_repo jenkins https://charts.jenkins.io
helm upgrade --install jenkins jenkins/jenkins -n jenkins \
  -f "$ROOT/platform/jenkins-values.yaml" --set controller.admin.password="$JENKINS_PASS" \
  --wait --timeout 15m

echo "Jenkins is up. The 'demo-app' job exists; run it once by hand, then polling takes over."
