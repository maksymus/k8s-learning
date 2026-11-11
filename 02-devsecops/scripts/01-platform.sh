#!/usr/bin/env bash
# TLS registry, the ghcr.io cache (remote hosts only), the CI tools image, and Kyverno.
source "$(dirname "$0")/lib.sh"

TLS="$KEYS/tls"
if [ ! -f "$TLS/ca.crt" ]; then
  log "Creating a private CA and a certificate for $SECURE_REG"
  mkdir -p "$TLS" && chmod 700 "$KEYS" "$TLS"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=k8s-learning lab CA" \
    -keyout "$TLS/ca.key" -out "$TLS/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$SECURE_REG" \
    -keyout "$TLS/tls.key" -out "$TLS/tls.csr" 2>/dev/null
  openssl x509 -req -days 825 -in "$TLS/tls.csr" -CA "$TLS/ca.crt" -CAkey "$TLS/ca.key" -CAcreateserial \
    -extfile <(printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "$SECURE_REG") \
    -out "$TLS/tls.crt" 2>/dev/null
fi

log "Starting registry '$SECURE_REG' with TLS"
if [ "$(docker inspect -f '{{.State.Running}}' "$SECURE_REG" 2>/dev/null || true)" != true ]; then
  docker rm -f "$SECURE_REG" >/dev/null 2>&1 || true
  docker create --restart=always -p "127.0.0.1:$SECURE_PORT:5000" --network kind --name "$SECURE_REG" \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/tls.crt -e REGISTRY_HTTP_TLS_KEY=/certs/tls.key registry:2 >/dev/null
  # docker cp instead of a bind mount, because the Docker host may be another machine
  docker cp "$TLS/." "$SECURE_REG:/certs"
  docker start "$SECURE_REG" >/dev/null
fi

log "Making the nodes trust the private CA for $REGISTRY"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/$REGISTRY"
  docker cp "$TLS/ca.crt" "$node:/etc/containerd/certs.d/$REGISTRY/ca.crt"
  printf '[host."https://%s"]\n  ca = "/etc/containerd/certs.d/%s/ca.crt"\n' "$REGISTRY" "$REGISTRY" |
    docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/$REGISTRY/hosts.toml"
done

# Same WSL2 workaround as project 1's 01-cluster.sh: Kyverno's images and Trivy's
# vulnerability database both come from ghcr.io.
if [ -n "$REMOTE_HOST" ]; then
  GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  log "Pull-through cache for ghcr.io on $GW:5013"
  if [ "$(docker inspect -f '{{.State.Running}}' cache-ghcr-io 2>/dev/null || true)" != true ]; then
    docker rm -f cache-ghcr-io >/dev/null 2>&1 || true
    docker run -d --restart=always --network host --name cache-ghcr-io \
      -e REGISTRY_HTTP_ADDR="$GW:5013" -e REGISTRY_PROXY_REMOTEURL=https://ghcr.io registry:2 >/dev/null
  fi
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" mkdir -p /etc/containerd/certs.d/ghcr.io
    printf 'server = "https://ghcr.io"\n[host."http://%s:5013"]\n  capabilities = ["pull", "resolve"]\n' "$GW" |
      docker exec -i "$node" cp /dev/stdin /etc/containerd/certs.d/ghcr.io/hosts.toml
  done
fi

log "Building the CI tools image"
docker build -q -t "localhost:$SECURE_PORT/$TOOLS_IMAGE" "$LAB/ci-tools"
docker push -q "localhost:$SECURE_PORT/$TOOLS_IMAGE"

log "Installing Kyverno"
helm_repo kyverno https://kyverno.github.io/kyverno
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --version "$KYVERNO_CHART" \
  -f "$LAB/platform/kyverno-values.yaml" --set-file admissionController.caCertificates.data="$TLS/ca.crt" \
  --wait --timeout 10m
