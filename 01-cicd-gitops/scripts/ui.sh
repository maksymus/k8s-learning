#!/usr/bin/env bash
# Forwards every UI to localhost and prints the logins. Ctrl-C to stop.
source "$(dirname "$0")/lib.sh"

# Restart loop, because a port-forward dies whenever its pod is replaced (e.g. on each deploy).
forward() {
  ( while true; do kubectl -n "$1" port-forward "svc/$2" "$3:$4" >/dev/null 2>&1; sleep 2; done ) &
  PF_PIDS+=($!)
}
forward gitea     gitea-http          3000 3000
forward sonarqube sonarqube-sonarqube 9000 9000
forward jenkins   jenkins             8080 8080
forward argocd    argocd-server       8081 80
forward demo-dev  demo-app            8000 80

ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '?')

cat <<INFO

  Gitea      http://localhost:3000   $GITEA_USER / $GITEA_PASS
  SonarQube  http://localhost:9000   admin / $SONAR_PASS
  Jenkins    http://localhost:8080   admin / $JENKINS_PASS
  Argo CD    http://localhost:8081   admin / $ARGO_PASS
  demo-app   http://localhost:8000   (once Argo CD has synced it)

Ctrl-C to stop forwarding.
INFO
# Background jobs of a script ignore Ctrl-C, so stop the loops and their kubectl children explicitly.
stop() {
  _cleanup
  pkill -f 'port-forward svc/(gitea-http|sonarqube-sonarqube|jenkins|argocd-server|demo-app) ' 2>/dev/null || true
  exit 0
}
trap stop INT TERM
wait
