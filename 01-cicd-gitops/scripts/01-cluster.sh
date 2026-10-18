#!/usr/bin/env bash
# kind cluster + local image registry (the pattern from kind's docs).
source "$(dirname "$0")/lib.sh"

# With REMOTE_HOST set, both containers below run on that machine (DOCKER_HOST, see lib.sh),
# and "localhost:$REG_PORT" means its localhost: that's where 05-argocd.sh's docker push runs too.
log "Starting local registry container '$REG_NAME' on localhost:$REG_PORT"
if [ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || true)" != true ]; then
  docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge --name "$REG_NAME" registry:2
fi

log "Creating kind cluster '$CLUSTER'"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  {
    cat "$ROOT/cluster/kind-config.yaml"
    # By default the API server only listens on the Docker host's 127.0.0.1, which is unreachable
    # from this Mac when the host is remote. Publish it on the LAN instead; it still requires
    # the client certificate that kind writes into ~/.kube/config.
    if [ -n "$REMOTE_HOST" ]; then
      printf 'networking:\n  apiServerAddress: "%s"\n  apiServerPort: 6443\n' "$REMOTE_IP"
    fi
  } | kind create cluster --config -
fi

log "Pointing the nodes' containerd at the registry: localhost:$REG_PORT -> http://$REG_NAME:5000"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${REG_PORT}"
  printf '[host."http://%s:5000"]\n' "$REG_NAME" |
    docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${REG_PORT}/hosts.toml"
done

# Put the registry on the kind network so nodes and pods can reach it by name
if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REG_NAME")" = null ]; then
  docker network connect kind "$REG_NAME"
fi

# Remote host only: under WSL2's mirrored networking, long downloads from containers break
# partway (connection reset), because their traffic goes through Docker's NAT. The host's own
# downloads are fine. So run pull-through caches on the host network, bound to the kind network's
# gateway IP: the node and pods reach them without NAT, and the caches fetch from the internet
# like the host does. containerd falls back to the real registry if a cache is down.
if [ -n "$REMOTE_HOST" ]; then
  GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  for spec in docker.io=https://registry-1.docker.io=5010 quay.io=https://quay.io=5011 \
              ecr-public.aws.com=https://ecr-public.aws.com=5012; do
    IFS='=' read -r reg upstream port <<<"$spec"
    name="cache-${reg//./-}"
    log "Pull-through cache for $reg on $GW:$port"
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" != true ]; then
      docker rm -f "$name" >/dev/null 2>&1 || true
      docker run -d --restart=always --network host --name "$name" \
        -e REGISTRY_HTTP_ADDR="$GW:$port" -e REGISTRY_PROXY_REMOTEURL="$upstream" registry:2 >/dev/null
    fi
    for node in $(kind get nodes --name "$CLUSTER"); do
      docker exec "$node" mkdir -p "/etc/containerd/certs.d/$reg"
      printf 'server = "%s"\n[host."http://%s:%s"]\n  capabilities = ["pull", "resolve"]\n' "$upstream" "$GW" "$port" |
        docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/$reg/hosts.toml"
    done
  done

  # BuildKit in the Jenkins agent pod pulls the Dockerfile's base image itself, so it needs the
  # Docker Hub cache too. ci/agent-pod.yaml mounts this ConfigMap as optional: without it
  # (local mode) BuildKit pulls directly.
  kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n jenkins create configmap buildkitd-config --from-literal=buildkitd.toml="$(printf \
    '[registry."docker.io"]\n  mirrors = ["%s:5010"]\n[registry."%s:5010"]\n  http = true\n' "$GW" "$GW")" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
YAML

log "Checking that pods can resolve '$REG_NAME' (the Jenkins build pushes there)"
# Trailing dot = exact name only. Without it, busybox also tries every search domain
# (e.g. your router's) and reports their NXDOMAINs as a failure.
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup "$REG_NAME." >/dev/null \
  && echo "ok" || echo "WARNING: pods cannot resolve $REG_NAME. Image pushes from Jenkins will fail."

kubectl get nodes
