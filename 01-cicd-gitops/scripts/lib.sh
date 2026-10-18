# Shared settings and helpers. Sourced by the numbered scripts.
# Throwaway passwords: none of these services is exposed beyond port-forwards on this machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=k8s-learning
REG_NAME=kind-registry
REG_PORT=5001

GITEA_USER=gitea_admin
GITEA_PASS=k8s-learning-123
SONAR_PASS='K8s-Learning-2026!'
JENKINS_PASS=k8s-learning

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Optional: run Docker and the kind cluster on another machine instead of this one.
# Set REMOTE_HOST to an SSH host (e.g. `export REMOTE_HOST=k8s-lab`, an alias from ~/.ssh/config).
# Everything else (kubectl, helm, git, port-forwards) still runs here and reaches the cluster
# through its API server, so only the Docker commands need to know about the remote host.
REMOTE_HOST="${REMOTE_HOST:-}"
if [ -n "$REMOTE_HOST" ]; then
  export DOCKER_HOST="ssh://$REMOTE_HOST"
  # kind publishes the API server on this address, so it must be the server's LAN IP
  REMOTE_IP=$(ssh -G "$REMOTE_HOST" 2>/dev/null | awk '/^hostname /{print $2}')
fi

# port_forward <namespace> <service> <local-port> <service-port>
# Runs in the background and is stopped when the script exits.
PF_PIDS=()
port_forward() {
  kubectl -n "$1" port-forward "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  for _ in $(seq 30); do
    nc -z localhost "$3" 2>/dev/null && return 0
    sleep 1
  done
  echo "port-forward to $1/$2 did not come up" >&2
  return 1
}
_cleanup() { for p in "${PF_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap _cleanup EXIT

helm_repo() { helm repo add "$1" "$2" >/dev/null 2>&1 || true; helm repo update "$1" >/dev/null; }
