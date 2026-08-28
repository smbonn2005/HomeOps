# Kopiur Template

The `kopiur` operator + `ClusterRepository` (`kubernetes/apps/storage/kopiur`)
are deployed and healthy. VolSync has been fully removed — every app,
including `kubevirt/rps`, is on `./backup`/`./populate`. For `rps`, CDI's
`DataVolume` only supports its own fixed set of source types (confirmed
against the live CRD schema, plus
[cdi-populators.md](https://github.com/kubevirt/containerized-data-importer/blob/main/doc/cdi-populators.md)) —
it can't be pointed at a Kopiur `Restore`. So `rps` dropped
`dataVolumeTemplates` entirely and now references a plain,
`./populate`-managed PVC directly via
`volumes[].persistentVolumeClaim.claimName`, the same shape every other
app uses.

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

## Changing a PVC's backing populator on an existing app: snapshot first, then swap

`PersistentVolumeClaim.spec.dataSourceRef` is immutable once a PVC is
bound — Flux's dry-run will reject changing it in place, and because Flux
applies a Kustomization's resources atomically, that single failure blocks
the *entire* Kustomization (nothing gets pruned or created, not just the
PVC) — a safe failure mode (the app keeps running on the old PVC), but it
means any such change has to happen in two steps:

1. Add `./snapshot` alongside whatever currently owns the PVC, no PVC
   changes at all. Confirm a real snapshot lands (check the
   `SnapshotPolicy` status, or trigger one manually with a `Snapshot` CR)
   before moving on.
2. Once a snapshot exists, add `./populate` (or swap to `./backup`) and
   delete the existing PVC first (scale the workload to 0, delete the PVC,
   then let Flux recreate it) — the new `Restore` populator will find the
   snapshot from step 1 and restore from it instead of starting empty.
   Check the underlying PV's `persistentVolumeReclaimPolicy` before doing
   this: `Delete` means the old volume's data is gone for good once the
   PVC is deleted, so step 1 isn't optional.

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

For an app that already has a bound PVC, see the two-step procedure above
instead.

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
