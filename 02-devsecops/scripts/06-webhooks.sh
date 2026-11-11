#!/usr/bin/env bash
# Replaces two minutes of polling with a push notification from Gitea to Jenkins.
source "$(dirname "$0")/lib.sh"

GITEA_CHART=12.7.0 # the version project 1 installed

log "Allowing Gitea to call in-cluster services"
helm_repo gitea-charts https://dl.gitea.com/charts/
helm upgrade --install gitea gitea-charts/gitea -n gitea --version "$GITEA_CHART" \
  -f "$ROOT/platform/gitea-values.yaml" -f "$LAB/platform/gitea-overrides.yaml" \
  --set gitea.admin.password="$GITEA_PASS" --wait --timeout 10m

port_forward gitea gitea-http 13000 3000
HOOKS="http://localhost:13000/api/v1/repos/$GITEA_USER/demo-app/hooks"
AUTH=(-u "$GITEA_USER:$GITEA_PASS")

# The url parameter must match the job's Git URL exactly, or Jenkins finds nothing to poll.
REPO=http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/demo-app.git
TARGET="http://jenkins.jenkins.svc.cluster.local:8080/git/notifyCommit?url=$REPO"

log "Creating the webhook on demo-app"
for id in $(curl -sf "${AUTH[@]}" "$HOOKS" | jq --arg t "$TARGET" '.[] | select(.config.url == $t) | .id'); do
  curl -sf "${AUTH[@]}" -X DELETE "$HOOKS/$id"
done
curl -sf "${AUTH[@]}" -H 'Content-Type: application/json' "$HOOKS" -d "$(jq -n --arg t "$TARGET" \
  '{type:"gitea", active:true, events:["push"], config:{url:$t, content_type:"json"}}')" | jq -r '"hook \(.id) created"'
