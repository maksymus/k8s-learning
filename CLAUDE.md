# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

A series of hands-on Kubernetes learning projects, each in its own numbered directory (`01-cicd-gitops/`, …). The root `README.md` lists planned projects; only project 1 exists so far. Project 2 (DevSecOps) is meant to extend project 1 by fixing the "Shortcuts taken" listed in `01-cicd-gitops/README.md` — keep those shortcuts intact in project 1 rather than "fixing" them there.

Target machine: Intel i5, 4 cores, 16 GB RAM, no GPU. Run only one project's stack at a time; project 1 needs Docker Desktop memory ≥ 10 GB.

## Project 1: `01-cicd-gitops/`

Everything runs in a local kind cluster (`k8s-learning`) with a local registry container (`kind-registry`, `localhost:5001`). Gitea is the in-cluster Git server, Jenkins does CI, SonarQube is the quality gate, Argo CD does CD.

### Commands

Setup is a sequence of idempotent scripts (run from `01-cicd-gitops/`, in order, all safe to re-run):

```bash
./scripts/00-check-prereqs.sh
./scripts/01-cluster.sh     # kind cluster + registry + containerd mirror config
./scripts/02-gitea.sh       # Gitea, creates repos, git-inits & pushes local dirs, Jenkins token secret
./scripts/03-sonarqube.sh   # SonarQube, admin password, analysis token secret
./scripts/04-jenkins.sh     # Jenkins via Helm + JCasC (requires secrets from 02 and 03)
./scripts/05-argocd.sh      # seeds demo-app:seed image, installs Argo CD, applies the Application
./scripts/ui.sh             # long-running port-forwards for all UIs + prints logins
./scripts/99-teardown.sh    # deletes cluster + registry; local repos are kept
```

Demo app (FastAPI, Python 3.12), from `01-cicd-gitops/demo-app/`:

```bash
pip install -r requirements-dev.txt
pytest                                  # pytest.ini sets pythonpath=. and testpaths=tests
pytest tests/test_main.py::test_name    # single test
pytest --cov=demo_app                   # coverage (CI enforces ≥80% on new code via Sonar)
uvicorn demo_app.main:app --port 8000
```

### Architecture (the key idea: CI and CD are split by a Git commit)

- `demo-app/` and `demo-app-manifests/` hold the **starting state** and are tracked in the root `k8s-learning` repo (GitHub, private). `02-gitea.sh` copies them on first run to gitignored `work/demo-app` and `work/demo-app-manifests`. Those are **separate git repos** (remote `gitea` on `localhost:3000`, which only works while `ui.sh` is forwarding), and the exercises happen there. A change meant for the lesson itself (e.g. `ci/agent-pod.yaml`) goes in the originals *and*, to reach the running Jenkins, must also be committed in `work/demo-app` and pushed to Gitea.
- **Jenkins never touches the cluster.** `demo-app/Jenkinsfile` runs in a per-build agent pod (`demo-app/ci/agent-pod.yaml`, one container per tool: `python`, `sonar`, `buildkit`, `git`) and does: tests → `sonar-scanner -Dsonar.qualitygate.wait=true` → BuildKit build/push to `kind-registry:5000` → clone `demo-app-manifests` and `sed` the `newTag:` line in `overlays/dev/kustomization.yaml`, then commit and push. That `newTag` line is the only thing CI edits; keep its format so the sed still matches.
- **Argo CD is the only deployer.** `argocd/demo-app-dev.yaml` syncs `demo-app-manifests/overlays/dev` into namespace `demo-dev` with `prune` + `selfHeal`.
- **Registry has two names:** pods push to `kind-registry:5000` (Docker network name); kind nodes pull `localhost:5001/...`, mapped via `/etc/containerd/certs.d` set up in `01-cluster.sh` (enabled by `cluster/kind-config.yaml`).
- Image tags are `<BUILD_NUMBER>-<short sha>`, baked into the image as `APP_VERSION` and returned by `GET /`. Initial tag is `seed`.
- **Jenkins is fully configured as code** in `platform/jenkins-values.yaml` (JCasC + job-dsl): credentials `gitea` and `sonar-token` come from k8s secrets `gitea-credentials` / `sonar-credentials` created by scripts 02/03; the `demo-app` pipeline job polls Gitea every 2 min (polling only starts after the first manual build). Change Jenkins config there, not in the UI.
- In-cluster service URLs used across files: `gitea-http.gitea.svc.cluster.local:3000`, `sonarqube-sonarqube.sonarqube.svc.cluster.local:9000`.
- **Optional remote host:** with `REMOTE_HOST=<ssh host>` set (the user's is `k8s-lab`, a WSL2 Docker host at 192.168.1.158), `lib.sh` exports `DOCKER_HOST=ssh://…` and `01-cluster.sh` adds `networking.apiServerAddress=<its IP>:6443` to the kind config piped into `kind create cluster --config -`. Only Docker/kind commands go remote; kubectl, helm, git and port-forwards stay on the Mac. In that mode `localhost:5001` (seed image push in 05) refers to the remote machine's localhost. Unset `REMOTE_HOST` = everything local, unchanged. Remote mode also starts pull-through caches (`cache-docker-io` :5010, `cache-quay-io` :5011, `cache-ecr-public-aws-com` :5012, host network, bound to the kind gateway IP) and node `certs.d/<registry>/hosts.toml` mirrors, plus a `jenkins/buildkitd-config` ConfigMap mounted optionally by `ci/agent-pod.yaml`. They're there because WSL2 mirrored networking resets long downloads that go through Docker's NAT. Conntrack `tcp_be_liberal`, MTU 1400 and GRO off were tried and did not fix it. Add a cache whenever a new chart pulls from another registry.
- Shared settings (cluster name, registry, throwaway local passwords) and helpers (`log`, `port_forward` with auto-cleanup, `helm_repo`) live in `scripts/lib.sh`, sourced by every script. Scripts use temporary port-forwards on 13000/19000 so they don't clash with `ui.sh` (3000/9000/8080/8081/8000).

### Style

The project is a teaching resource: scripts, YAML, and the Jenkinsfile carry short comments explaining *why*. Keep scripts short, idempotent, and readable, and the `README.md` exercises consistent with any behavior changes.

### Debugging

```bash
kubectl get pods -A | grep -v Running
kubectl -n argocd get application demo-app-dev -o json | jq .status
kubectl -n sonarqube logs sonarqube-sonarqube-0     # SonarQube restarts: memory / vm.max_map_count
kubectl -n jenkins get pods -w                       # watch build agent pods
```
