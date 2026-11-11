# Project 2: DevSecOps

Extends the running project 1 stack by fixing its "Shortcuts taken". This directory holds only the changes. The scripts deliver them to Gitea and the cluster, and project 1's own files stay as they were.

## The flow

```
 git push ──► Gitea ──webhook──► Jenkins (one rootless agent pod per build)
                                  1. tests + quality gate
                                  2. build + push ─────────► secure-registry (TLS)
                                  3. Trivy scan by digest    fails on fixable HIGH/CRITICAL
                                  4. SBOM + cosign signature only reached if the scan passed
                                  5. commit the digest ────► demo-app-manifests
                                                                  │
                                 Argo CD syncs it                 ▼
                                  ┌─────────────────────────────────────────────┐
                                  │ admission for namespace demo-dev            │
                                  │  Kyverno: right registry, signed by CI key  │
                                  │  Pod Security: "restricted"                 │
                                  └─────────────────────────────────────────────┘
                                  running pods: default-deny NetworkPolicies
```

**The idea to take away: the signature is what connects CI to the cluster.** The image is pushed before it's scanned, so being in the registry proves nothing. Only an image that passed every gate gets signed, and the cluster refuses anything unsigned. Jenkins still has no cluster credentials.

## Layout

| Path | What it is |
|---|---|
| `ci-tools/Dockerfile` | One image with cosign, Trivy and kubeseal, pinned, with a shell for Jenkins |
| `demo-app/` | Replaces the `Jenkinsfile`, `ci/agent-pod.yaml`, `Dockerfile` and `requirements.txt` |
| `demo-app-manifests/` | `overlays/dev` with the digest, the namespace labels and the NetworkPolicies |
| `policies/verify-images.yaml.tpl` | Kyverno `ImageValidatingPolicy`; `02-signing.sh` fills in the public key |
| `platform/` | Kyverno values, and overrides layered on project 1's Jenkins and Gitea values |
| `argocd/platform-secrets.yaml` | Argo CD `Application` for the sealed Jenkins secrets |
| `.keys/` | Signing key, private CA, sealing key backup. **Gitignored: this repo is public** |

## Setup

Project 1 must be up, including a first run of its `04-jenkins.sh`, because Jenkins here reuses the plugins on that PVC. Kyverno and the other additions use about 1 GB more memory.

```bash
cd ~/Projects/k8s-learning/02-devsecops
export REMOTE_HOST=k8s-lab         # only if the stack runs on the remote host
./scripts/01-platform.sh           # TLS registry, tools image, Kyverno
./scripts/02-signing.sh            # signing key, admission policy
./scripts/03-jenkins.sh            # signing credentials, CA and BuildKit config for builds
./scripts/04-gitops.sh             # signed seed image; pipeline and manifests into Gitea
./scripts/05-sealed-secrets.sh     # encrypts Jenkins's secrets into Git
./scripts/06-webhooks.sh           # Gitea notifies Jenkins on push
```

All are safe to re-run. `04-gitops.sh` overwrites project 2's files in `../01-cicd-gitops/work/` but keeps the digest Jenkins last deployed. Project 1's `ui.sh` still gives you every UI.

Then build `demo-app` once in Jenkins. `curl localhost:8000` should show the new version.

## Exercises

Do these in `../01-cicd-gitops/work/`.

1. **Follow one change.** Change the greeting and its test, then push. Find the digest in the Jenkins log, the manifests commit, and the running pod. Then run `kubectl -n demo-dev get pod -o yaml | grep image:` and explain why it's a digest and not a tag.

2. **Fail the scan.** In `work/demo-app/requirements.txt`, go back to `fastapi==0.115.6` and push. Trivy reports HIGH findings in `starlette`. Check which stages ran, then look in the registry: the image is there, but it has no `sha256-….sig` tag. Why is that safe?

3. **Deploy something unsigned.** Push any image to `localhost:5002` and commit its digest to `overlays/dev/kustomization.yaml`. Find where the refusal shows up: the Argo CD UI, the ReplicaSet's events, or both? Note that the old pods keep serving. Then `git revert`.

4. **Try to get around the policy.** Use `kubectl -n demo-dev apply --dry-run=server` with a pod that uses `docker.io/library/nginx`, one that uses a tag rather than a digest, and one with an init container from another registry. The first version of this policy only checked images matching the registry glob, so nginx got through. Read the first rule in `verify-images.yaml.tpl` and work out why.

5. **Pod Security.** Add `privileged: true` to a dry-run pod and read the message. Then remove the `seccompProfile` patch from the overlay and push. What happens to the rollout?

6. **NetworkPolicies.** From an app pod, try to connect out:
   ```bash
   kubectl -n demo-dev exec deploy/demo-app -- python -c "import socket; socket.create_connection(('1.1.1.1',443),4)"
   ```
   It times out. Delete `default-deny` and watch what restores it. Why does the app need no DNS?

7. **Why rootless isn't the whole answer.** Read the `buildkit` container in `ci/agent-pod.yaml`, then try it against PSS `baseline`. It runs as non-root with no extra privileges, but it needs `Unconfined` seccomp. Which is worse: that, or `privileged`? What would it take to run builds in a `baseline` namespace?

8. **Lose the sealing key.** Read `05-sealed-secrets.sh`. What happens to the files in `platform-secrets/` if the cluster is rebuilt and `.keys/sealing-key.yaml` is gone? Why does that one file need a backup when everything else comes back from Git?

9. **Measure the webhook.** Push a commit and time how long the build takes to start, then compare with project 1's polling. Argo CD still polls every 60 seconds: Gitea's `ROOT_URL` is `localhost:3000`, so the repo URL in a webhook wouldn't match the one Argo CD knows. How would you fix that?

## What's still a shortcut

| Shortcut | Why it's left |
|---|---|
| `kubectl`-created secrets at bootstrap, passwords in `lib.sh` and git remotes | Sealed Secrets covers the secrets in the cluster. The first admin password has to come from somewhere; a real setup uses a secret manager |
| Signing key held by Jenkins | Keyless signing needs an OIDC identity and Sigstore services |
| No transparency log | The lab is private. In public, Rekor makes signatures auditable |
| Registry has TLS but no login | Anything on the kind network can push, though it can't sign |
| `jenkins` namespace has no Pod Security level | Rootless BuildKit can't pass `baseline` (exercise 7) |
| Kyverno has one replica | It fails closed for labelled namespaces only, so an outage blocks `demo-dev` rollouts and nothing else |

## When something breaks

```bash
kubectl -n demo-dev get events --sort-by=.lastTimestamp         # admission refusals
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50
kubectl get imagevalidatingpolicies.policies.kyverno.io
kubectl -n jenkins get sealedsecrets
```

- **`jenkins-0` stuck in `Init` after a node restart, under project 1's values.** The chart's plugin copy crashes on a reused volume, or plugin downloads hang on a WSL host. `03-jenkins.sh` removes that step.
- **The kind node shows `Exited (128)` after WSL starts.** A startup race with systemd. Run `docker start k8s-learning-control-plane`.
- **`pip` finds no versions during the image build.** A network reset on a WSL host. Run the build again.
- **`failed to verify certificate` from Kyverno.** Its trust bundle comes from `--set-file` in `01-platform.sh`, so re-run that after recreating the CA.

## Findings worth keeping

Tested with Kyverno 1.19.2 and cosign 3.1.4:
- Kyverno cannot read cosign signatures from a plain-HTTP registry. `allowInsecureRegistry` did not help with plain HTTP or with a private CA, so the registry has TLS and Kyverno trusts the CA.
- `verifyImages` in `ClusterPolicy` is deprecated, so this lab uses `ImageValidatingPolicy`.
- An empty `cosign signing-config` is how cosign 3 signs without a transparency log; `--tlog-upload=false` is deprecated.
