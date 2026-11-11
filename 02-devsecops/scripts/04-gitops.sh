#!/usr/bin/env bash
# Signs a seed image, then delivers the project 2 pipeline and manifests through Gitea.
source "$(dirname "$0")/lib.sh"

log "Copying project 1's demo-app:seed to $REGISTRY and signing it"
docker pull -q "localhost:$REG_PORT/demo-app:seed" >/dev/null
docker tag "localhost:$REG_PORT/demo-app:seed" "localhost:$SECURE_PORT/demo-app:seed"
docker push -q "localhost:$SECURE_PORT/demo-app:seed" >/dev/null
SEED=$(docker inspect -f '{{index .RepoDigests 0}}' "localhost:$SECURE_PORT/demo-app:seed" | cut -d@ -f2)
docker run --rm --network kind -e COSIGN_PASSWORD="$(cat "$KEYS/password")" \
  -e COSIGN_PRIVATE_KEY="$(cat "$KEYS/cosign.key")" -e CA="$(cat "$KEYS/tls/ca.crt")" \
  "localhost:$SECURE_PORT/$TOOLS_IMAGE" sh -c "
    mkdir /tmp/ca && printf '%s\n' \"\$CA\" >/tmp/ca/ca.crt && export SSL_CERT_DIR=/etc/ssl/certs:/tmp/ca
    cosign signing-config create --out /tmp/sc.json
    cosign sign --yes --key env://COSIGN_PRIVATE_KEY --signing-config /tmp/sc.json $REGISTRY/demo-app@$SEED"

port_forward gitea gitea-http 13000 3000

log "Delivering the pipeline to Gitea"
pull demo-app
deliver demo-app "$LAB/demo-app"

# Only the first run starts from the seed. After that the digest belongs to Jenkins,
# and re-running this script must not roll the app back.
pull demo-app-manifests
CURRENT=$(sed -n 's/.*digest: "\(.*\)"/\1/p' "$ROOT/work/demo-app-manifests/overlays/dev/kustomization.yaml")
CURRENT=${CURRENT:-$SEED}

log "Delivering the manifests to Gitea (digest $CURRENT)"
TMP=$(mktemp -d)
cp -R "$LAB/demo-app-manifests/." "$TMP/"
sed "s|__SEED_DIGEST__|$CURRENT|" "$LAB/demo-app-manifests/overlays/dev/kustomization.yaml" >"$TMP/overlays/dev/kustomization.yaml"
deliver demo-app-manifests "$TMP"
rm -rf "$TMP"

echo "Watch it roll out: kubectl -n argocd get application demo-app-dev -w"
