#!/usr/bin/env bash
# Gitea: hosts the demo-app (source) and demo-app-manifests (GitOps) repos.
source "$(dirname "$0")/lib.sh"

log "Installing Gitea"
helm_repo gitea-charts https://dl.gitea.com/charts/
helm upgrade --install gitea gitea-charts/gitea -n gitea --create-namespace \
  -f "$ROOT/platform/gitea-values.yaml" --set gitea.admin.password="$GITEA_PASS" \
  --wait --timeout 10m

port_forward gitea gitea-http 13000 3000
API=http://localhost:13000/api/v1
AUTH=(-u "$GITEA_USER:$GITEA_PASS")

log "Creating repositories"
for repo in demo-app demo-app-manifests; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$API/repos/$GITEA_USER/$repo")
  if [ "$code" = 404 ]; then
    curl -sf "${AUTH[@]}" -H 'Content-Type: application/json' \
      -d "{\"name\":\"$repo\",\"default_branch\":\"main\"}" "$API/user/repos" >/dev/null
    echo "created $repo"
  else
    echo "$repo already exists"
  fi
done

# demo-app/ and demo-app-manifests/ are the starting point (tracked in the k8s-learning repo).
# The first run copies each into work/<repo> (gitignored), which becomes the working copy of
# the Gitea repo. Exercises happen there; the originals stay as they were.
# The 'gitea' remote uses port 3000, which scripts/ui.sh forwards.
push_repo() {
  local repo=$1
  [ -d "$ROOT/work/$repo" ] || { mkdir -p "$ROOT/work"; cp -R "$ROOT/$repo" "$ROOT/work/$repo"; }
  (
    cd "$ROOT/work/$repo"
    if [ ! -d .git ]; then
      git init -q -b main
      git add -A
      git -c user.name=you -c user.email=you@local commit -qm "Initial commit"
    fi
    git remote remove gitea 2>/dev/null || true
    git remote add gitea "http://$GITEA_USER:$GITEA_PASS@localhost:3000/$GITEA_USER/$repo.git"
    git push -q "http://$GITEA_USER:$GITEA_PASS@localhost:13000/$GITEA_USER/$repo.git" main \
      && echo "pushed $repo" \
      || echo "push of $repo skipped (remote has newer commits; run 'git pull gitea main' there)"
  )
}
log "Pushing local repos to Gitea"
push_repo demo-app
push_repo demo-app-manifests

log "Creating an access token for Jenkins"
curl -s -X DELETE "${AUTH[@]}" "$API/users/$GITEA_USER/tokens/jenkins" >/dev/null || true
TOKEN=$(curl -sf "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"jenkins","scopes":["write:repository"]}' \
  "$API/users/$GITEA_USER/tokens" | jq -r .sha1)

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins create secret generic gitea-credentials \
  --from-literal=username="$GITEA_USER" --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
