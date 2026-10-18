# demo-app-manifests

Desired state of demo-app in every environment. Argo CD syncs `overlays/dev` into the `demo-dev` namespace.

- `base/` holds what every environment shares
- `overlays/<env>/` holds per-environment differences, including the image tag

Humans change structure here through commits. Jenkins only ever bumps `newTag`.
Rolling back means `git revert`.
