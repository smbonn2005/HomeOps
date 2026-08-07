# Kopiur Template

The `kopiur` operator + `ClusterRepository` (`kubernetes/apps/storage/kopiur`)
are deployed and healthy. `speedtest` (`apps/default/speedtest`) piloted
these components: a manual snapshot of its live VolSync-owned PVC
succeeded, then it was cut over to `./backup` (VolSync removed, PVC
recreated via the `Restore` populator) as the first full migration. Other
apps should follow the same two-step procedure below before switching.

## Four components

- `./secret` — the shared `kopiur-repository-secret` `ExternalSecret`. Must
  be added once to **every namespace's top-level `kustomization.yaml`**
  that has an app using Kopiur (not per-app) — Kopiur's mover pods run in
  the app's own namespace and can only mount a `Secret` that exists
  locally there, so the secret needs to exist in `storage` (for the
  `ClusterRepository` controller itself) *and* in each consuming
  namespace. This is why `kopiur-repository/ks.yaml` also pulls in
  `../../../../components/kopiur/secret`.
- `./snapshot` — just the `SnapshotPolicy`/`SnapshotSchedule` for an app,
  targeting an existing PVC by name. Doesn't touch the PVC itself.
- `./populate` — the PVC + `Restore` (populator mode) pair that provisions
  a PVC from the latest snapshot for an app's `SnapshotPolicy`.
- `./backup` — a convenience bundle of `./snapshot` + `./populate`, for a
  brand new app with **no pre-existing PVC**.

## Migrating an app off VolSync: snapshot first, then swap

**Do not add `./backup` (or `./populate`) directly to an app that already
has a VolSync-managed, bound PVC.** `PersistentVolumeClaim.spec.dataSourceRef`
is immutable once a PVC is bound — Flux's dry-run will reject changing it
from VolSync's `ReplicationDestination` to Kopiur's `Restore` in place, and
because Flux applies a Kustomization's resources atomically, that single
failure blocks the *entire* Kustomization (nothing gets pruned or created,
not just the PVC). This is exactly what happened on the first speedtest
attempt: `spec.dataSourceRef` dry-run failed and the whole apply aborted,
which is a safe failure mode (the app keeps running on the old PVC), but
it also means the migration has to happen in two steps:

1. Add **`./volsync` and `./snapshot` together** (not `./backup`) to the
   app's `ks.yaml`. This lets Kopiur back up the PVC VolSync still owns,
   with no PVC changes at all. Confirm a real snapshot lands
   (`kubectl kopiur snapshots list -n <ns>` or check the `SnapshotPolicy`
   status) before moving on.
2. Once a snapshot exists, swap `./volsync` → `./populate` (keep
   `./snapshot`). Applying this requires deleting the existing PVC first
   (scale the workload to 0, delete the PVC, then let Flux recreate it) —
   the new `Restore` populator will find the snapshot from step 1 and
   restore from it instead of starting empty. Check the underlying PV's
   `persistentVolumeReclaimPolicy` before doing this: `Delete` means the
   old volume's data is gone for good once the PVC is deleted, so step 1
   isn't optional.

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
app's namespace `kustomization.yaml`. For a brand new app:

```yaml
# apps/<namespace>/<app>/ks.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
spec:
  components:
    - ../../../../components/kopiur/backup
```

For an app migrating off VolSync, see the two-step procedure above instead.

```yaml
# apps/<namespace>/kustomization.yaml
components:
  - ../../components/kopiur/secret
```

## Required `postBuild` vars

- `APP`: The application name
- `KOPIUR_CAPACITY`: The PVC size (also used as the mover's cache PVC
  size) — only needed when using `./populate` or `./backup`

## Optional `postBuild` vars

- `CLAIM`: PVC name, if different from `APP`
- `KOPIUR_ACCESSMODES`: default `ReadWriteOnce`
- `KOPIUR_STORAGECLASS`: default `ceph-block`
- `KOPIUR_CACHE_CAPACITY`: default `2Gi`
- `KOPIUR_SNAPSHOTCLASS`: default `csi-ceph-blockpool`
- `KOPIUR_PUID` / `KOPIUR_PGID`: default `1000`
