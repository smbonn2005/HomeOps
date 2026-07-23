# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a personal home infrastructure monorepo, not an application codebase. It defines a Talos Linux + Kubernetes cluster and everything deployed to it, managed via GitOps: Flux reconciles the `kubernetes/` directory, Renovate opens PRs for dependency/version bumps, and GitHub Actions validates changes. There is no application source code to build — "changes" here are almost always YAML manifests.

## Common commands

Task (`go-task`) is the primary interface; run `task` (or `task --list`) for the full list. Tasks are namespaced by the includes in `Taskfile.yaml`: `bootstrap:*`, `kubernetes:*`, `talos:*`, `volsync:*`, `workstation:*`.

Local environment expects `KUBECONFIG=./kubeconfig`, `TALOSCONFIG=./talosconfig`, and `MINIJINJA_CONFIG_FILE=./.minijinja.toml` (set automatically via `.envrc`/`direnv` or `.mise.toml`).

Validating manifest changes (what CI runs, do this before considering a `kubernetes/` change done):
- `bash scripts/kubeconform.sh ./kubernetes` — builds every kustomization with `kustomize build` and validates the output against Kubernetes/CRD schemas via `kubeconform`.
- `docker run --rm -v "$PWD:/github/workspace" ghcr.io/allenporter/flux-local:v8.3.0 test --enable-helm --all-namespaces --path /github/workspace/kubernetes/flux/cluster -v` — mirrors the `flux-local` GitHub Action (`.github/workflows/flux-local.yaml`), which also runs a `flux-local diff` against `main` on every PR and posts it as a comment.
- To sanity-check a single app's rendered manifests: `kustomize build --load-restrictor=LoadRestrictionsNone kubernetes/apps/<namespace>/<app>/app`.

Cluster/Talos operations (require live cluster access via `kubeconfig`/`talosconfig`, so only relevant when explicitly asked to operate on the live cluster, not for manifest-only changes):
- `task bootstrap ROOK_DISK=<disk-model>` — bootstrap Talos nodes + cluster apps (destructive, first-install only).
- `task talos:apply-node IP=<ip>` / `task talos:upgrade-node IP=<ip>` / `task talos:upgrade-k8s` — Talos node config/upgrades.
- `task kubernetes:sync-secrets` — force-reconcile all `ExternalSecret`s.
- `task kubernetes:cleanse-pods` — delete pods stuck in Failed/Pending/Succeeded.
- `task volsync:state-suspend` / `task volsync:state-resume`, `task volsync:unlock`, `task volsync:snapshot` — VolSync backup control.

No traditional lint/test/build step exists for this repo; `kubeconform`/`flux-local` (above) are the correctness gate, and `.editorconfig`/`.shellcheckrc` govern formatting/shell scripts under `scripts/`.

## Architecture

### Directory layout

```
kubernetes/
├── apps/          # Workloads, grouped by namespace (default, media, monitoring, networking, kube-system, ...)
├── components/    # Reusable kustomize components shared across apps
└── flux/cluster/  # Single top-level Flux Kustomization that Flux actually watches
bootstrap/         # helmfile used for one-time cluster bootstrap (installs Flux itself, etc.)
talos/             # Talos machine config templates (minijinja .yaml.j2), rendered per-node
scripts/           # bootstrap-cluster.sh, kubeconform.sh, render-machine-config.sh
.taskfiles/        # Task definitions included by the root Taskfile.yaml
```

### Flux reconciliation model

Flux watches only `kubernetes/flux/cluster` (see `kubernetes/flux/cluster/ks.yaml`), a single `Kustomization` (`cluster-apps`) pointed at `./kubernetes/apps`. From there Flux recursively finds every `kustomization.yaml` under `kubernetes/apps`, starting with per-namespace `kustomization.yaml` files (e.g. `kubernetes/apps/default/kustomization.yaml`) that list each app's `ks.yaml`.

Each app follows a fixed two-level structure:
- `kubernetes/apps/<namespace>/<app>/ks.yaml` — a Flux `Kustomization` pointing at `./kubernetes/apps/<namespace>/<app>/app`, declaring `dependsOn` for ordering (e.g. wait for `cloudnative-pg-cluster` or `external-secrets-stores` first) and often including shared components like `../../../../components/volsync` or `../../../../components/defaults`.
- `kubernetes/apps/<namespace>/<app>/app/` — the actual resources: `kustomization.yaml`, `helmrelease.yaml`, and usually `externalsecret.yaml`.

`HelmRelease`s almost universally use the shared `app-template` chart (`chartRef: OCIRepository app-template`, from `kubernetes/components/common/repos/app-template`) rather than each app's own chart — application config lives entirely in `values:` (controllers/containers/service/route/persistence, etc.), not in a chart-specific schema. New apps should follow this same `values.controllers.<name>.containers.app` pattern rather than inventing a new shape.

Cross-resource dependencies are expressed at two levels: `Kustomization.spec.dependsOn` (higher-level, e.g. "don't apply this namespace's apps until rook-ceph is healthy") and `HelmRelease.spec.dependsOn` (e.g. "don't install this release until `rook-ceph-cluster` and `volsync` are ready"). When adding or editing an app, check both for correctness — most `HelmRelease`s depend on `rook-ceph-cluster` (namespace `rook-ceph`) and `volsync` (namespace `storage`) since nearly everything uses persistent storage.

### Shared components (`kubernetes/components/`)

- `common` — adds the namespace resource and the `app-template` OCIRepository reference; included by nearly every namespace-level `kustomization.yaml`.
- `defaults` — a kustomize `Component` that patches every `HelmRelease` (v2) with standard `install`/`upgrade` remediation settings (retries, `crds: CreateReplace`, `cleanupOnFail`). Any HelmRelease-affecting change should keep this patch compatible.
- `volsync` — adds VolSync `ReplicationSource`/`ReplicationDestination`/PVC resources for apps that need backup/restore; consumed via `postBuild.substitute` vars like `APP` and `VOLSYNC_CAPACITY` set in the app's `ks.yaml`.

### Secrets

Secrets are never stored in-cluster or in git as plain `Secret` objects. Every app that needs credentials has an `externalsecret.yaml` (`external-secrets.io/v1 ExternalSecret`) pulling from a 1Password Connect `ClusterSecretStore` (`onepassword-connect`), templated into a target `Secret` consumed via `envFrom` in the `HelmRelease`. Don't hand-write `Secret` manifests — add/extend an `ExternalSecret` instead.

### Renovate

`.renovaterc.json5` extends shared presets from `home-operations/renovate-presets` and layers repo-specific `packageRules` (allowed version pins, automerge policies for OCI digests/GitHub Actions/specific charts). Commit messages/PR titles for dependency bumps follow the `type(scope): update ...` convention visible in git log — preserve this style if manually editing versions Renovate would otherwise manage.

### Networking

Ingress is done entirely through `envoy-gateway` (Gateway API `HTTPRoute`s in each app's `route:` values block, e.g. `parentRefs` → `envoy-internal` or `envoy-external` Gateway in the `networking` namespace) — no classic `Ingress` resources. External access flows through a Cloudflare Tunnel (`cloudflared`); `external-dns` watches the `envoy-external` gateway/HTTPRoutes and syncs public DNS records to Cloudflare, while `unifi-dns` syncs internal-only records to the UniFi controller for LAN resolution.
