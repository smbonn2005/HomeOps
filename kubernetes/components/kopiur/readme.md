# Kopiur Template

The `kopiur` operator + `ClusterRepository` (`kubernetes/apps/storage/kopiur`)
are deployed. These per-app components (`./secret`, `./backup`) are not yet
wired into any app — hold off referencing them from an app's `ks.yaml`
until the operator has been confirmed healthy on the live cluster. See the
VolSync equivalent at `../volsync` for the pattern this replaces.

This layout is adapted from a known-working production deployment of this
chart, keeping the operator and repository in this repo's existing
`storage` namespace instead of a dedicated `kopiur-system` one.
Unlike VolSync (one restic repo per app, isolated by path prefix), Kopiur
here uses a **single shared `ClusterRepository`** (`garage`, defined in
`kubernetes/apps/storage/kopiur/repository`) — one secret, one bucket,
referenced by every app's `SnapshotPolicy`.

## Two components, two different places to add them

- `./secret` — the shared `kopiur-repository-secret` `ExternalSecret`. Must
  be added once to **every namespace's top-level `kustomization.yaml`**
  that has an app using Kopiur (not per-app) — Kopiur's mover pods run in
  the app's own namespace and can only mount a `Secret` that exists
  locally there, so the secret needs to exist in `storage` (for the
  `ClusterRepository` controller itself) *and* in each consuming
  namespace. This is why `kopiur-repository/ks.yaml` also pulls in
  `../../../../components/kopiur/secret`.
- `./backup` — the per-app `SnapshotPolicy`/`SnapshotSchedule`/`Restore`/PVC,
  added to an individual app's `ks.yaml` `components:`, same as VolSync's
  component was.

## Flux Kustomization

This requires `postBuild` configured on the Flux Kustomization

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app plex
  namespace: flux-system
spec:
  # ...
  postBuild:
    substitute:
      APP: *app
      KOPIUR_CAPACITY: 5Gi
```

and then call the components in your application's `ks.yaml` and the
app's namespace `kustomization.yaml`:

```yaml
# apps/<namespace>/<app>/ks.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
spec:
  components:
    - ../../../../components/kopiur/backup
```

```yaml
# apps/<namespace>/kustomization.yaml
components:
  - ../../components/kopiur/secret
```

## Required `postBuild` vars

- `APP`: The application name
- `KOPIUR_CAPACITY`: The PVC size (also used as the mover's cache PVC size)

## Optional `postBuild` vars

- `CLAIM`: PVC name, if different from `APP`
- `KOPIUR_ACCESSMODES`: default `ReadWriteOnce`
- `KOPIUR_STORAGECLASS`: default `ceph-block`
- `KOPIUR_CACHE_CAPACITY`: default `2Gi`
- `KOPIUR_SNAPSHOTCLASS`: default `csi-ceph-blockpool`
- `KOPIUR_PUID` / `KOPIUR_PGID`: default `1000`
