#!/usr/bin/env bash
# Argo CD: watches demo-app-manifests and keeps the cluster in sync with it.
source "$(dirname "$0")/lib.sh"

log "Seeding the registry with demo-app:seed (the tag the manifests start with)"
docker build -q -t "localhost:$REG_PORT/demo-app:seed" --build-arg APP_VERSION=seed "$ROOT/demo-app"
docker push -q "localhost:$REG_PORT/demo-app:seed"

log "Installing Argo CD"
helm_repo argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f "$ROOT/platform/argocd-values.yaml" --wait --timeout 10m

log "Registering the demo-app-dev Application"
kubectl apply -f "$ROOT/argocd/demo-app-dev.yaml"

echo "Watch it sync: kubectl -n argocd get application demo-app-dev -w"
