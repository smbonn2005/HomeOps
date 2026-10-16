# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a personal home infrastructure monorepo, not an application codebase. It defines a Talos Linux + Kubernetes cluster and everything deployed to it, managed via GitOps: Flux reconciles the `kubernetes/` directory, Renovate opens PRs for dependency/version bumps, and GitHub Actions validates changes. There is no application source code to build — "changes" here are almost always YAML manifests.

## Common commands

`just` is the primary interface; run `just` (or `just -l`) for the full list. Recipes are namespaced by the modules in `.justfile`: `just bootstrap ...`, `just kube ...`, `just talos ...`.

Local environment expects `KUBECONFIG=./kubeconfig`, `TALOSCONFIG=./talosconfig`, and `MINIJINJA_CONFIG_FILE=./.minijinja.toml` (set automatically by `mise` from `.mise/config.toml`, which also pins every CLI the recipes use).

Validating manifest changes (do this before considering a `kubernetes/` change done):
- `kustomize build --load-restrictor=LoadRestrictionsNone <dir> | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://cluster-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'` per kustomization — validates rendered output against Kubernetes/CRD schemas. CI does not run this; `flate` (below) is the workflow gate.
- `docker run --rm -v "$PWD:/workspace" -w /workspace ghcr.io/home-operations/flate:latest test all --path ./kubernetes/apps` — offline Flux reconcile (no cluster, no `helm`/`kustomize`/`flux` CLIs) with pytest-style `PASS`/`FAIL`/`SKIPPED` per `Kustomization`/`HelmRelease`, non-zero exit on any failure; run this locally before pushing. `flate` is the Go rewrite of `flux-local`.
- To sanity-check a single app's rendered manifests: `kustomize build --load-restrictor=LoadRestrictionsNone kubernetes/apps/<namespace>/<app>/app`.

PR-time rendering (diffs against `main`, status checks) is handled by Konflate (`kubernetes/apps/flux-system/konflate`), a webhook-driven in-cluster app that replaced the old `flux-local` GitHub Action — there's nothing to invoke manually for that part.

Cluster/Talos operations (require live cluster access via `kubeconfig`/`talosconfig`, so only relevant when explicitly asked to operate on the live cluster, not for manifest-only changes):
- `just bootstrap cluster [disk]` — bootstrap Talos nodes + cluster apps (destructive, first-install only). Wipes the disks Rook consumes on every node before Flux starts; `disk` defaults to `nvme0n1` and matches either a device id or a disk model.
- `just talos apply-node <node>` / `just talos upgrade-node <node>` / `just talos upgrade-k8s <version>` — Talos node config/upgrades.
- `just kube sync-es` — force-reconcile all `ExternalSecret`s.
- `just kube prune-pods` — delete pods stuck in Failed/Pending/Succeeded.

No traditional lint/test/build step exists for this repo; `kubeconform`/`flate` (above) are the correctness gate, and `.editorconfig` governs formatting.

## Architecture

### Directory layout

```
kubernetes/
├── apps/          # Workloads, grouped by namespace (default, media, monitoring, networking, kube-system, ...)
└── components/    # Reusable kustomize components shared across apps
bootstrap/         # helmfile used for one-time cluster bootstrap (installs Flux itself, etc.)
talos/             # Talos machine config templates (minijinja .yaml.j2), rendered per-node; see talos/README.md
.justfile          # Root just modules (bootstrap/mod.just, kubernetes/mod.just, talos/mod.just)
```

### Flux reconciliation model

Flux is managed by the flux-operator `FluxInstance` (`kubernetes/apps/flux-system/flux-instance`), whose `sync` block points the root `flux-system` `Kustomization` directly at `kubernetes/apps`; there is no in-repo top-level Flux `Kustomization`. From there Flux builds each per-namespace `kustomization.yaml` (e.g. `kubernetes/apps/default/kustomization.yaml`), which lists that namespace's `namespace.yaml` plus each app's `ks.yaml`.

The `FluxInstance`'s `kustomize.patches` inject HelmRelease defaults (`install`/`upgrade` remediation, retries, `crds: CreateReplace`, `cleanupOnFail`) into every child `Kustomization`, so app `ks.yaml` files don't include a defaults component. Because the patch uses `op: add` on `/spec/patches`, a child `Kustomization` that sets its own `spec.patches` would have them overwritten.

Each app follows a fixed two-level structure:
- `kubernetes/apps/<namespace>/<app>/ks.yaml` — a Flux `Kustomization` pointing at `./kubernetes/apps/<namespace>/<app>/app`, declaring `dependsOn` for ordering (e.g. wait for `cloudnative-pg-cluster` or `external-secrets-stores` first) and sometimes including shared components like `../../../../components/kopiur/backup`.
- `kubernetes/apps/<namespace>/<app>/app/` — the actual resources: `kustomization.yaml`, `helmrelease.yaml`, `ocirepository.yaml`, and usually `externalsecret.yaml`.

Each namespace directory owns its `Namespace` object in `kubernetes/apps/<namespace>/namespace.yaml` (with `kustomize.toolkit.fluxcd.io/prune: disabled`), listed first in that namespace's `kustomization.yaml`.

`HelmRelease`s almost universally use the `app-template` chart rather than each app's own chart — application config lives entirely in `values:` (controllers/containers/service/route/persistence, etc.), not in a chart-specific schema. New apps should follow this same `values.controllers.<name>.containers.app` pattern rather than inventing a new shape.

There is no shared `app-template` source: each app-template app has its own `OCIRepository` in `app/ocirepository.yaml`, named after the app and referenced by name (e.g. `chartRef: {kind: OCIRepository, name: plex}` with `url: oci://ghcr.io/bjw-s-labs/helm/app-template`). HelmReleases sharing an `app/` directory share its one `OCIRepository` (e.g. `mysql` and `mysql-backup` both use `mysql`). Don't set `metadata.namespace` on these; the enclosing kustomization supplies it. A chart bump touches every copy, so keep their `ref.tag` in sync.

Cross-resource dependencies are expressed at two levels: `Kustomization.spec.dependsOn` (higher-level, e.g. "don't apply this app until `kopiur-repository` is ready") and `HelmRelease.spec.dependsOn` (e.g. "don't install this release until `rook-ceph-cluster` and `kopiur` are ready"). When adding or editing an app, check both for correctness — most `HelmRelease`s depend on `rook-ceph-cluster` (namespace `rook-ceph`) and `kopiur` (namespace `storage`) since nearly everything uses persistent storage.

### Shared components (`kubernetes/components/`)

- `kopiur` — backup/restore for apps needing persistent storage, replacing VolSync (fully removed cluster-wide). Four sub-components: `secret` (the shared `kopiur-repository-secret` `ExternalSecret`, added to each consuming namespace's top-level `kustomization.yaml`), `snapshot` (`SnapshotPolicy`/`SnapshotSchedule` for an existing PVC), `populate` (PVC + `Restore` populator that provisions a PVC from the latest snapshot), and `backup` (`snapshot` + `populate` bundled, for brand-new apps with no pre-existing PVC). Consumed via `postBuild.substitute` vars like `APP` and `KOPIUR_CAPACITY` set in the app's `ks.yaml`; see `kubernetes/components/kopiur/readme.md` for the full variable list and the two-step procedure required when swapping an existing PVC's populator (`dataSourceRef` is immutable once bound).

### Secrets

Secrets are never stored in-cluster or in git as plain `Secret` objects. Every app that needs credentials has an `externalsecret.yaml` (`external-secrets.io/v1 ExternalSecret`) pulling from a 1Password Connect `ClusterSecretStore` (`onepassword-connect`), templated into a target `Secret` consumed via `envFrom` in the `HelmRelease`. Don't hand-write `Secret` manifests — add/extend an `ExternalSecret` instead.

### Renovate

`.renovaterc.json5` extends shared presets from `home-operations/renovate-presets` and layers repo-specific `packageRules` (allowed version pins, automerge policies for OCI digests/GitHub Actions/specific charts). Commit messages/PR titles for dependency bumps follow the `type(scope): update ...` convention visible in git log — preserve this style if manually editing versions Renovate would otherwise manage.

### Networking

Ingress is done entirely through `envoy-gateway` (Gateway API `HTTPRoute`s in each app's `route:` values block, e.g. `parentRefs` → `envoy-internal` or `envoy-external` Gateway in the `networking` namespace) — no classic `Ingress` resources. External access flows through a Cloudflare Tunnel (`cloudflared`); `external-dns` watches the `envoy-external` gateway/HTTPRoutes and syncs public DNS records to Cloudflare, while `unifi-dns` syncs internal-only records to the UniFi controller for LAN resolution.
