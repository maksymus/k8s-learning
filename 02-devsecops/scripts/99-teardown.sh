#!/usr/bin/env bash
# Removes project 2's containers, then runs project 1's teardown (cluster + registry).
# .keys/ is kept, so a rebuilt cluster can still decrypt the sealed secrets in work/.
source "$(dirname "$0")/lib.sh"
docker rm -f "$SECURE_REG" cache-ghcr-io >/dev/null 2>&1 || true
"$ROOT/scripts/99-teardown.sh"
