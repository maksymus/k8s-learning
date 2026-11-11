# The tools CI uses to scan and sign, in one image with a shell.
# Jenkins runs stages through `sh`, and the official cosign image is distroless (no shell).
# Versions are pinned: your scanner and signer are part of your supply chain too.
FROM alpine:3.22
RUN apk add --no-cache ca-certificates curl jq
COPY --from=ghcr.io/sigstore/cosign/cosign:v3.1.4 /ko-app/cosign /usr/local/bin/cosign
COPY --from=docker.io/aquasec/trivy:0.76.2 /usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=docker.io/bitnami/sealed-secrets-kubeseal:0.41.2 /usr/local/bin/kubeseal /usr/local/bin/kubeseal
WORKDIR /work
