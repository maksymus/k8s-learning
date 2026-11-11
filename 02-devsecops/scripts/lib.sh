# Project 2 builds on the running project 1 stack, so it shares its settings and helpers.
source "$(dirname "${BASH_SOURCE[0]}")/../../01-cicd-gitops/scripts/lib.sh"

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_IMAGE=ci-tools:2
KYVERNO_CHART=3.9.2

# A second registry, with TLS, beside project 1's plain-HTTP one. Kyverno cannot read cosign
# signatures over plain HTTP (allowInsecureRegistry did not help when tested with 1.19.2).
# One name everywhere, because Kyverno runs in a pod, where localhost is the pod itself.
SECURE_REG=secure-registry
SECURE_PORT=5002 # published on the Docker host's 127.0.0.1, for pushes from scripts
REGISTRY="$SECURE_REG:5000"
KEYS="$LAB/.keys" # gitignored: this repo is public

# Helpers for updating the Gitea repos. They need `port_forward gitea gitea-http 13000 3000` first.
url() { echo "http://$GITEA_USER:$GITEA_PASS@localhost:13000/$GITEA_USER/$1.git"; }
pull() { git -C "$ROOT/work/$1" pull -q --rebase "$(url "$1")" main; }

# deliver <repo> <dir>: copy files over the working copy, then commit and push if anything changed.
deliver() {
  local work="$ROOT/work/$1"
  cp -R "$2/." "$work/"
  git -C "$work" add -A
  git -C "$work" diff --cached --quiet || git -C "$work" \
    -c user.name=you -c user.email=you@local commit -qm "Project 2: DevSecOps changes"
  git -C "$work" push -q "$(url "$1")" main
}
