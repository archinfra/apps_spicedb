# apps_spicedb

SpiceDB Kubernetes offline `.run` installer package.

This package delivers the official SpiceDB container image as a self-extracting offline `.run` installer. The installer loads the image, retags it for an internal registry, pushes it, renders Kubernetes manifests, runs datastore migrations, and deploys SpiceDB.

## Version

- SpiceDB: `v1.54.0`
- default namespace: `spicedb`
- default replicas: `2`
- default datastore engine: `postgres`
- default service type: `ClusterIP`
- default image source: `docker.io/authzed/spicedb:v1.54.0`
- default retarget image: `sealos.hub:5000/kube4/authzed/spicedb:v1.54.0`

The upstream changelog lists `1.54.0` as the latest released section at the time this package was created.

## What this package creates

- Namespace
- Secret: `spicedb-config`
- Migration Job: `spicedb-migrate`
- Service: `spicedb`
- Deployment: `spicedb`

Service ports:

```text
gRPC:    50051
HTTP:    8443
Metrics: 9090
```

## Important model

SpiceDB is not an authentication system. It is an authorization database inspired by Google Zanzibar. Your application writes schemas and relationships into SpiceDB, then asks SpiceDB whether a subject can perform an action on a resource.

This installer does not deploy PostgreSQL. Production installs should use an external PostgreSQL, CockroachDB, MySQL, or Spanner datastore. The default path is PostgreSQL.

## Build locally

Build host requirements:

- Linux shell
- Docker
- Python 3
- `tar`
- `sha256sum`

No `jq` is required.

Build one architecture:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Build both:

```bash
bash build.sh --arch all
```

Artifacts are written to `dist/`:

```text
dist/spicedb-1.54.0-amd64.run
dist/spicedb-1.54.0-amd64.run.sha256
dist/spicedb-1.54.0-arm64.run
dist/spicedb-1.54.0-arm64.run.sha256
```

## Target host requirements

Target host requirements:

- `bash`
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`, `sed`, `base64`
- `docker`, unless `--skip-image-prepare` is used
- `kubectl`
- optional `sha256sum`, only for checking the `.sha256` file before running the installer

The target host does **not** need `jq` or Python.

## Prepare PostgreSQL

Create a PostgreSQL database first. Example connection string:

```text
postgres://postgres:password@postgres.default.svc.cluster.local:5432/spicedb?sslmode=disable
```

The installer will run:

```bash
spicedb datastore migrate head --datastore-engine postgres --datastore-conn-uri ...
```

## Install

```bash
sha256sum -c spicedb-1.54.0-amd64.run.sha256
chmod +x spicedb-1.54.0-amd64.run

./spicedb-1.54.0-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -n spicedb \
  --datastore-engine postgres \
  --datastore-conn-uri 'postgres://postgres:password@postgres.default.svc.cluster.local:5432/spicedb?sslmode=disable' \
  --grpc-preshared-key 'change-me-to-a-long-random-key' \
  -y
```

If the target registry already contains the SpiceDB image:

```bash
./spicedb-1.54.0-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n spicedb \
  --datastore-engine postgres \
  --datastore-conn-uri 'postgres://postgres:password@postgres.default.svc.cluster.local:5432/spicedb?sslmode=disable' \
  --grpc-preshared-key 'change-me-to-a-long-random-key' \
  -y
```

Expose as NodePort when needed:

```bash
./spicedb-1.54.0-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --service-type NodePort \
  --nodeport-grpc 32051 \
  --nodeport-http 32443 \
  -n spicedb \
  --datastore-engine postgres \
  --datastore-conn-uri 'postgres://postgres:password@postgres.default.svc.cluster.local:5432/spicedb?sslmode=disable' \
  --grpc-preshared-key 'change-me-to-a-long-random-key' \
  -y
```

## Temporary memory mode

For local smoke testing only:

```bash
./spicedb-1.54.0-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --datastore-engine memory \
  --grpc-preshared-key 'change-me-to-a-long-random-key' \
  -n spicedb \
  -y
```

Memory mode is not persistent and skips datastore migration.

## Status

```bash
./spicedb-1.54.0-amd64.run status -n spicedb
kubectl get pods,svc,deploy,job -n spicedb -l app.kubernetes.io/name=spicedb
```

Check service:

```bash
kubectl get svc -n spicedb spicedb
kubectl logs -n spicedb deploy/spicedb
kubectl logs -n spicedb job/spicedb-migrate
```

## Client access

In cluster, use:

```text
spicedb.spicedb.svc.cluster.local:50051
```

Clients must send the gRPC preshared key as the authentication token.

With `zed`:

```bash
zed context set local spicedb.spicedb.svc.cluster.local:50051 'change-me-to-a-long-random-key' --insecure
zed schema read --context local
```

## Uninstall

```bash
./spicedb-1.54.0-amd64.run uninstall -n spicedb -y
```

Delete namespace too:

```bash
./spicedb-1.54.0-amd64.run uninstall -n spicedb --delete-namespace -y
```

The installer does not delete your external PostgreSQL database or SpiceDB tables.

## Production notes

- Use a real datastore, preferably PostgreSQL or CockroachDB, not `memory`.
- Use a long random `--grpc-preshared-key` and store it securely.
- This package does not enable TLS by default. Put it behind trusted internal networking, service mesh, or an ingress/gateway with TLS.
- Run migrations before serving traffic. The installer does this by default for non-memory datastores.
- The official SpiceDB image uses a minimal userspace, so the Kubernetes manifest avoids `/bin/sh` and uses only image entrypoint args.

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds both `amd64` and `arm64` artifacts on:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.
