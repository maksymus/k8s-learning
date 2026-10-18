#!/usr/bin/env bash
# Deletes the cluster and registry. Your working copies in work/ are kept.
source "$(dirname "$0")/lib.sh"
kind delete cluster --name "$CLUSTER"
docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
echo "Gone. Re-run 01..05 to rebuild; the scripts are safe to re-run."
