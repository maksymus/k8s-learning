#!/usr/bin/env bash
# Encrypts Jenkins's secrets so they can live in Git. Only this cluster's controller can open them.
source "$(dirname "$0")/lib.sh"

BACKUP="$KEYS/sealing-key.yaml"

# The sealing key is the one thing Git can't give back. Restoring it before the controller
# starts means a rebuilt cluster can still decrypt everything already in Git.
[ -f "$BACKUP" ] && { log "Restoring the sealing key from backup"; kubectl apply -f "$BACKUP"; }

log "Installing the Sealed Secrets controller"
helm_repo sealed-secrets https://bitnami.github.io/sealed-secrets
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n kube-system --version 2.22.0 \
  --set fullnameOverride=sealed-secrets-controller --wait --timeout 5m

KEY_SELECTOR=sealedsecrets.bitnami.com/sealed-secrets-key=active
until [ -n "$(kubectl -n kube-system get secret -l "$KEY_SELECTOR" -o name)" ]; do sleep 2; done
kubectl -n kube-system get secret -l "$KEY_SELECTOR" -o yaml >"$BACKUP"
chmod 600 "$BACKUP"
CERT=$(kubectl -n kube-system get secret -l "$KEY_SELECTOR" -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d)

OUT=$(mktemp -d)
mkdir "$OUT/platform-secrets"
for s in gitea-credentials sonar-credentials cosign-credentials; do
  log "Sealing $s"
  # Without this the controller won't take over a Secret that it didn't create.
  kubectl -n jenkins annotate secret "$s" sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
  # Runs in the tools image, so kubeseal doesn't have to be installed on this machine
  kubectl -n jenkins get secret "$s" -o json |
    jq 'del(.metadata.annotations, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.ownerReferences)' |
    docker run --rm -i -e CERT="$CERT" "localhost:$SECURE_PORT/$TOOLS_IMAGE" \
      sh -c 'printf "%s" "$CERT" >/tmp/cert; kubeseal --cert /tmp/cert -o yaml' >"$OUT/platform-secrets/$s.yaml"
done

log "Committing the sealed secrets to Gitea"
port_forward gitea gitea-http 13000 3000
pull demo-app-manifests
deliver demo-app-manifests "$OUT"
rm -rf "$OUT"

kubectl apply -f "$LAB/argocd/platform-secrets.yaml"
