#!/usr/bin/env bash
# Creates the CI signing key once, gives Jenkins the private half, Kyverno the public half.
source "$(dirname "$0")/lib.sh"

if [ ! -f "$KEYS/cosign.key" ]; then
  log "Generating the signing key pair"
  mkdir -p "$KEYS" && chmod 700 "$KEYS"
  PASS=$(openssl rand -hex 16)
  # Generated in a container and streamed back, so no volume is needed on a remote Docker host
  docker run --rm -e COSIGN_PASSWORD="$PASS" "localhost:$SECURE_PORT/$TOOLS_IMAGE" \
    sh -c 'cosign generate-key-pair >/dev/null 2>&1 && tar c cosign.key cosign.pub' | tar x -C "$KEYS"
  printf '%s' "$PASS" >"$KEYS/password"
  chmod 600 "$KEYS"/*
fi

log "Giving Jenkins the private key"
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins create secret generic cosign-credentials \
  --from-file=key="$KEYS/cosign.key" --from-file=password="$KEYS/password" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying the admission policy with the public key"
sed 's/^/            /' "$KEYS/cosign.pub" >"$KEYS/pub.indented"
sed -e "/__COSIGN_PUB__/{r $KEYS/pub.indented" -e 'd;}' "$LAB/policies/verify-images.yaml.tpl" | kubectl apply -f -
