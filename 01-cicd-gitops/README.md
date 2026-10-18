# Project 1: CI/CD with GitOps

Jenkins (CI) + SonarQube (quality gate) + Argo CD (CD), all running inside a local kind cluster, with Gitea as the Git server.

## The flow

```
  you: git push
        │
        ▼
 ┌─────────────┐  polls every 2 min  ┌───────────────────────────────────────────────┐
 │ Gitea       │ ◄────────────────── │ Jenkins  (one throwaway agent pod per build)  │
 │  demo-app   │                     │  1. unit tests + coverage       [python]      │
 │             │                     │  2. quality gate ──────────────► SonarQube    │
 │             │                     │  3. build + push image ────────► registry     │
 │  demo-app-  │ ◄── commit newTag ─ │  4. bump tag in manifests repo  [git]         │
 │  manifests  │                     └───────────────────────────────────────────────┘
 └──────┬──────┘
        │ polls every 60 s
        ▼
 ┌─────────────┐   applies overlays/dev   ┌────────────────────────────┐
 │ Argo CD     │ ───────────────────────► │ namespace demo-dev         │
 └─────────────┘   reverts manual drift   │  Deployment + Service      │
                                          └────────────────────────────┘
```

**The idea to take away: CI and CD are split by a Git commit.**
- Jenkins has no cluster credentials. Its last act is a commit to `demo-app-manifests`.
- Argo CD is the only thing that changes workloads. It pulls from Git instead of being pushed to.
- So the manifests repo's history *is* your deployment log. Rolling back means `git revert`, and auditing means `git log`.
- A failed stage (tests, quality gate) stops the pipeline before the commit, so nothing reaches the cluster.

## Layout

| Path | What it is |
|---|---|
| `demo-app/` | **Source repo.** FastAPI app, tests, `Dockerfile`, `Jenkinsfile`, `ci/agent-pod.yaml`, `sonar-project.properties` |
| `demo-app-manifests/` | **GitOps repo.** Kustomize `base/` + `overlays/dev/`. The only thing CI changes is `newTag` |
| `argocd/demo-app-dev.yaml` | Argo CD `Application`: "keep `demo-dev` equal to `overlays/dev`" |
| `platform/*-values.yaml` | Helm values for each tool. Jenkins is fully configured as code (JCasC): credentials and the job are defined here |
| `cluster/kind-config.yaml` | Single-node kind cluster |
| `scripts/` | Numbered setup steps, `ui.sh`, `99-teardown.sh`. All safe to re-run |
| `work/` | Your working copies of the two Gitea repos (gitignored, created by `02-gitea.sh`) |

`demo-app/` and `demo-app-manifests/` are the starting point. On its first run, `02-gitea.sh` copies them to `work/demo-app/` and `work/demo-app-manifests/`, turns each copy into its own git repo (remote `gitea`) and pushes it. Do the exercises in `work/`. The originals stay untouched, so a fresh clone always starts from the same state.

## Setup

**Before starting:**
1. `brew install helm jq`
2. Start Docker Desktop and set **Settings → Resources → Memory ≥ 10 GB**. The whole stack uses about 7 GB.

Run the steps one at a time and read each script first. They're short, and they're part of the lesson.

```bash
cd ~/Projects/k8s-learning/01-cicd-gitops
./scripts/00-check-prereqs.sh
./scripts/01-cluster.sh      # kind cluster + local registry        (~2 min)
./scripts/02-gitea.sh        # Git server, repos, Jenkins token      (~2 min)
./scripts/03-sonarqube.sh    # SonarQube + analysis token            (~5 min)
./scripts/04-jenkins.sh      # Jenkins via Helm + JCasC              (~5 min)
./scripts/05-argocd.sh       # Argo CD + the Application             (~3 min)
./scripts/ui.sh              # in a separate terminal: all UIs + logins
```

Then open Jenkins at http://localhost:8080, click the **demo-app** job, and choose **Build Now**. Polling only starts after the first build has run. Watch the agent pod start up:

```bash
kubectl -n jenkins get pods -w
```

When it finishes, Argo CD (http://localhost:8081) rolls out the new tag, and `curl localhost:8000` shows `"version": "1-abc1234"`.

### Running it on another machine

The stack can run on a second machine on your network (here, a Windows laptop with Docker Engine in WSL2) while you keep working on the Mac:

```bash
export REMOTE_HOST=k8s-lab      # an SSH host from ~/.ssh/config, with key login that needs no prompt
./scripts/00-check-prereqs.sh   # then 01..05 and ui.sh exactly as above
```

Only the Docker commands move. `lib.sh` sets `DOCKER_HOST=ssh://$REMOTE_HOST`, so `docker` and `kind` drive the remote daemon, and `01-cluster.sh` publishes the API server on the remote machine's LAN IP (port 6443) instead of its `127.0.0.1`. `kubectl`, `helm`, `git` and every port-forward still run on the Mac and reach the cluster through that API server. That's why `localhost:3000`, `:8080` and the other URLs keep working unchanged.

One WSL-specific workaround is built in. With WSL's mirrored networking, long downloads made *from inside containers* get reset partway (Docker's NAT is the trigger; the host's own downloads are fine). So in remote mode `01-cluster.sh` also starts pull-through caches for docker.io, quay.io and ecr-public.aws.com on the host network. Both the kind node's containerd and the build's BuildKit (through the optional `buildkitd-config` ConfigMap that `ci/agent-pod.yaml` mounts) pull through them.

Set `REMOTE_HOST` in every terminal that runs 00, 01, 05 or 99. `ui.sh`, 02, 03 and 04 only use `kubectl` and don't need it. The remote machine needs a fixed IP (a DHCP reservation in your router), because kind writes the IP into `~/.kube/config` and into the API server's certificate.

## Exercises

Work through these in order. Each one teaches one idea.

1. **The happy path.** Change the greeting in `work/demo-app/demo_app/main.py` and update its test. Then run `git commit -am ... && git push gitea main`. Follow the change through Jenkins (stage view), SonarQube (new analysis), the manifests repo in Gitea (a new commit by "Jenkins"), Argo CD (sync), and finally `curl localhost:8000`. Time each hop, find where the latency comes from, and work out how webhooks would remove it.

2. **Break the tests.** Push a failing test. Check which stages ran and whether anything reached the manifests repo.

3. **Fail the quality gate.** Add an endpoint with no tests. The default "Sonar way" gate requires ≥ 80% coverage on *new code*. Find the reason for the failure in the SonarQube UI. Then think about why the gate checks only new code instead of the whole codebase.

4. **Drift and self-heal.** Run `kubectl -n demo-dev scale deploy demo-app --replicas=5`. Watch Argo CD undo it. Next, turn off `selfHeal` in `argocd/demo-app-dev.yaml`, re-apply, and repeat. Look at what the UI shows now.

5. **Roll back with Git.** In `work/demo-app-manifests`, run `git pull gitea main`, then `git revert HEAD`, then `git push gitea main`. You rolled back without touching Jenkins or kubectl. Compare this with `argocd app rollback`, and think about why a GitOps team prefers the revert.

6. **Add a prod environment.** Create `overlays/prod` with 3 replicas and a `demo-prod` namespace, plus a second Application. Decide how a tag should get from dev to prod: automatic, a manual commit, or a pull request. This is *promotion*, and it's the design question interviewers ask about.

7. **Rebuild from scratch.** Run `99-teardown.sh` and then 01–05 again. Everything comes back, including Jenkins's job and credentials. That's what configuration as code and GitOps give you. Note what did *not* survive (SonarQube history, build logs) and why.

## Shortcuts taken (on purpose)

Each of these is something project 2 (DevSecOps) fixes:

| Shortcut | Why it's a problem | Fix in project 2 |
|---|---|---|
| BuildKit runs `privileged` | A compromised build could take over the node | Rootless BuildKit, Pod Security Standards |
| Plain-HTTP registry, no image scan | Unknown CVEs ship | Trivy scan gate, SBOM |
| Images are not signed | The cluster runs whatever the tag points to | cosign + Kyverno admission policy |
| Passwords in `lib.sh` and git remotes | Secrets leak through files | Sealed Secrets / External Secrets |
| SCM polling | Slow, and wastes resources | Webhooks |
| SonarQube with embedded DB | Loses data, can't scale | Fine to keep for learning |

## When something breaks

```bash
kubectl get pods -A | grep -v Running                 # anything stuck?
kubectl -n <ns> describe pod <pod>                     # Events at the bottom explain most failures
kubectl -n <ns> logs <pod> [-c <container>] --previous
kubectl -n argocd get application demo-app-dev -o json | jq .status  # why Argo CD isn't syncing
```

Likely problems on the first run:
- **SonarQube keeps restarting** because it hit the memory limit or the `vm.max_map_count` check. Look at `kubectl -n sonarqube logs sonarqube-sonarqube-0`.
- **Build stage can't push** because pods can't resolve `kind-registry`. `01-cluster.sh` checks for this.
- **Pods show `ErrImagePull` for `localhost:5001/...`** because the containerd registry config is missing. Re-run `01-cluster.sh`.
