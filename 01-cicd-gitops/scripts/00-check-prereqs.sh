#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

missing=0
for cmd in docker kind kubectl helm jq git curl nc; do
  if command -v "$cmd" >/dev/null; then echo "ok       $cmd"; else echo "MISSING  $cmd"; missing=1; fi
done
[ "$missing" = 0 ] || { echo; echo "Install the missing tools, e.g.: brew install helm jq"; exit 1; }

if [ -n "$REMOTE_HOST" ]; then
  echo "Remote Docker host: $REMOTE_HOST ($REMOTE_IP)"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" true 2>/dev/null \
    || { echo "Cannot SSH to $REMOTE_HOST without a prompt. Check that it's awake and that 'ssh $REMOTE_HOST' works."; exit 1; }
  docker info >/dev/null 2>&1 || { echo "Docker is not running on $REMOTE_HOST. Try: ssh $REMOTE_HOST sudo systemctl start docker"; exit 1; }
else
  docker info >/dev/null 2>&1 || { echo "Docker daemon is not running. Start Docker Desktop."; exit 1; }
fi

mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
echo "Docker memory: ${mem_gb} GB"
if [ "$mem_gb" -lt 9 ]; then
  echo "WARNING: this stack needs ~8 GB. Give Docker more memory (Docker Desktop > Settings > Resources, or memory= in .wslconfig on a WSL host)."
fi
