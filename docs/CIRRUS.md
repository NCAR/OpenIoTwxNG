# Running OpenIoTwx on Kubernetes (NCAR CIRRUS)

This is the hand-off for putting the site on a Kubernetes cluster that deploys from git with Argo CD, the way CIRRUS does. The security rules the server enforces are in [DEPLOY.md](DEPLOY.md); this page is about the cluster.

Everything was rehearsed from scratch on a local Kubernetes (`node deploy/k8s/rehearse.mjs`): the image builds, the pods start under strict security settings, migrations run, the security test passes, readings survive pods being killed and restarted under live uploads, and the backup job writes a readable dump. It has **not** been run on CIRRUS itself: that needs the access and answers listed under "What we assumed".

## How a change reaches the cluster

```
git push to main ──► GitHub Actions: typecheck, tests, build, check the Kubernetes files,
                     build the image, scan it, publish it as  <registry>/openiotwxng:<commit>
                 ──► someone (or a bot) sets newTag to that commit in the overlay  (a commit)
                 ──► Argo CD notices the commit  ──► runs the migration job (PreSync)
                                                 ──► rolls the Deployment out, one pod at a time
```

The cluster pulls from git (Argo CD), and nothing pushes into the cluster. Changes are made in git, never with `kubectl apply` by hand.

## What is where

| Path | What it is |
| --- | --- |
| `Dockerfile` | One image for the web app, the API and the station upload endpoint. Runs as the non-root `node` user. |
| `deploy/k8s/base/` | Deployment, Service, migration Job, PodDisruptionBudget, ServiceAccount. |
| `deploy/k8s/components/` | Optional pieces: `ingress`, `postgres` (a bundled database), `backup` (nightly dump), `networkpolicy`. |
| `deploy/k8s/overlays/example/` | The starting point for a real cluster. Copy it and change every `CHANGE-ME`. |
| `deploy/k8s/overlays/cirrus/` | The CIRRUS deployment (what Argo CD watches). |
| `deploy/k8s/overlays/rehearsal/` | The local rehearsal. |
| `deploy/k8s/secret.example.yaml` | The Secret the app reads (a template; real values never go in git). |
| `deploy/argocd/application.example.yaml` | An Argo CD Application pointing at an overlay. |
| `deploy/argocd/application.cirrus.yaml` | The Application for CIRRUS, to hand to the CIRRUS team. |
| `.github/workflows/ci.yml` | The checks and the image build. |
| `scripts/check-manifests.mjs` | Fails the build if the Kubernetes files weaken (root user, writable filesystem, floating image tag, a Secret in git, ...). |
| `deploy/k8s/rehearse.mjs` | The full local rehearsal. |

The Kubernetes files use Kustomize (built into `kubectl`, and native to Argo CD), so no other tool is needed. If the platform team prefers a Helm chart, the same files convert directly.

## What the CIRRUS team told us (November 2026)

These answers are from the CIRRUS team and from the mesonet application they already run (`NCAR/mesonet-siparcs25`, branch `cirrus`, folder `cloud/helm/`). `deploy/k8s/overlays/cirrus/` is built from them.

| Topic | Answer | Where it is in the files |
| --- | --- | --- |
| Where the files live | Argo CD can watch any git repository and branch. We use branch `cirrus` of this repository, folder `deploy/k8s/overlays/cirrus`. The CIRRUS team adds the repository and branch on their side. | `deploy/argocd/application.cirrus.yaml` |
| Namespace | Our own: `openiotwx` (added next to `mesonet`). | overlay `namespace:` |
| Public address | The app can be public with no VPN. Names can only be under `k8s.ucar.edu`: `openiotwx.k8s.ucar.edu`. Another name under `ucar.edu` needs an IT ticket for an alias. | overlay ingress patch, `BETTER_AUTH_URL` |
| HTTPS certificates | Automatic, by an annotation on the Ingress (`cert-manager.io/cluster-issuer: incommon`). The class is Traefik: `traefik-external` (public) or `traefik-internal` (UCAR network or VPN), as in NCAR/cirrus-examples. We use `traefik-external`. | overlay ingress patch |
| Image registry | The CIRRUS registry, `hub.k8s.ucar.edu`, project `openiotwx` (we are an admin of it). | overlay `images:` |
| Image builds | GitHub Actions is switched off for the NCAR organisation. A ticket to ithelp asks to allow `OpenIoTwxNG` (contact: Joel Daves), or CIRRUS-hosted runners can be used. Until then an image is built and pushed by hand (below). | `.github/workflows/ci.yml` |
| Database | The mesonet Postgres could be shared; we chose our own dedicated one, so we never touch their data. | `components/postgres` |
| Secrets | Not typed into the cluster. They come from the vault (OpenBao, `bao.k8s.ucar.edu`, sign in with OIDC) through an `ExternalSecret`, as mesonet does with `iotwx/cirrus`. We ask for our own path (for example `openiotwx/cirrus`) and a read-only SecretStore in our namespace. | `components/externalsecret` |
| Sign-in for people | Their preference is Entra ID (OIDC). Not built; administrators use `scripts/make-admin.mjs`. | later |
| Review before going live | Nothing specific. Names and the URL must not clash with mesonet. A failed first deployment breaks nothing and tells them what went wrong. | all names start with `openiotwx` |

**Order matters.** A dedicated database means the passwords, the database and the migration are all part of this deployment. So the overlay runs them in order (Argo CD "sync waves"): passwords (-2), database (-1), migration (5), then the app (10). `scripts/check-manifests.mjs` checks this order.

### Still to confirm

- The ingress class name. In their example it is `traefik-<visibility>`; check with `kubectl get ingressclass`.
- The SecretStore name and our vault path (`CHANGE-ME` in `components/externalsecret/externalsecret.yaml`).
- The Argo CD project name, and read access for Argo CD to this private repository (`application.cirrus.yaml`).
- The storage class for the database volume (the cluster default is used until told otherwise), and whether to turn on the nightly `backup`.
- Whether the registry project is public, or the namespace needs a pull secret.
- Whether `ollama-server` may be used by the chat.

### Publish an image by hand (until Actions is allowed)

```
docker login hub.k8s.ucar.edu -u <your-ucar-email>      # the password is the "CLI secret" from your Harbor profile
docker build -t hub.k8s.ucar.edu/openiotwx/openiotwxng:<commit> .
docker push hub.k8s.ucar.edu/openiotwx/openiotwxng:<commit>
```

Use the short git commit (`git rev-parse --short HEAD`) as the tag, then put the same tag in `newTag` of the overlay. Never use `latest`.

## First deployment, step by step

1. **Image.** Merge to `main`; CI publishes `<registry>/openiotwxng:<commit>`. If the registry is private, the namespace needs a pull secret.
2. **Overlay.** Copy `deploy/k8s/overlays/example` and set: the namespace, the image name and the commit tag, `BETTER_AUTH_URL` (the public https address), and the ingress host and class.
3. **Secret.** Create `openiotwx` in the namespace with `DATABASE_URL` and `BETTER_AUTH_SECRET` (`openssl rand -base64 48`). Tokens (`HUB_TOKEN`, `INGEST_BRIDGE_TOKEN`, `GDEX_RELEASE_TOKEN`, 24+ characters) and `SMTP_URL` are optional. See `deploy/k8s/secret.example.yaml`.
4. **Database.** Either point `DATABASE_URL` at a shared Postgres (a UTF-8 database and a user for the app), or add the `postgres` component and create the Secret `openiotwx-db` with `POSTGRES_PASSWORD`.
5. **Argo CD.** Create the Application (`deploy/argocd/application.example.yaml`) pointing at the overlay. It runs the migration job, then the Deployment.
6. **Check.** `kubectl -n <ns> get pods` shows the app ready, and `https://<host>/api/health` answers `{"ok":true,...}`. A misconfigured server answers 503 and logs why.
7. **First administrator.** Open the site and sign up with your email. Then:
   ```
   kubectl -n <ns> exec deploy/openiotwx -- node scripts/make-admin.mjs you@ucar.edu superadmin
   ```
   Sign in again. (Without `kubectl exec`, run the same SQL in a database console: `update profiles set role = 'superadmin' where lower(email) = lower('you@ucar.edu');`.)

## Day to day

- **Update:** merge to `main`, then change `newTag` in the overlay to the new commit. Argo CD does the rest. A rolling update keeps every pod's replacement ready before the old one stops, and a stopping pod flushes the readings it holds in memory first.
- **Roll back:** revert the `newTag` commit (or use Argo CD's rollback). Migrations only add; a rollback of the code does not undo them.
- **Logs:** `kubectl -n <ns> logs deploy/openiotwx`. A configuration problem is named in the log (`Unsafe production configuration ...`).
- **Scale:** change `replicas` in a patch. Readings are written in batches, so each pod holds a small buffer; sign-in limits are per pod.
- **Backups:** with the `backup` component a nightly job writes `openiotwx-<time>.dump` to its own volume and keeps 14 days; each dump is read back once before it is kept. A dump on the same cluster does not protect against losing the cluster, so also copy them elsewhere. With TimescaleDB, `pg_dump` prints warnings about "circular foreign-key constraints" on its internal `hypertable` and `chunk` tables; that is expected, and the restore steps below handle it. Restore: `pg_restore --clean --if-exists --no-owner -d "$DATABASE_URL" <file>` (with TimescaleDB, wrap it in `timescaledb_pre_restore()` and `timescaledb_post_restore()`).
- **Rotate the session secret:** change `BETTER_AUTH_SECRET`. Everyone is signed out, and CHORDS portal keys saved by users stop decrypting (they are encrypted with a key derived from it).

## What we assumed (change these when the answers are known)

Each assumption is one setting. Nothing here is hard-wired. (The registry, Argo CD, hostname and class, namespace, database and secrets rows were written before the CIRRUS team answered; the section above, "What the CIRRUS team told us", replaces them.)

| We assumed | Because we did not know | Where to change it |
| --- | --- | --- |
| Images live at `ghcr.io/ncar/openiotwxng` | which registry the cluster pulls from | overlay `images:` and the repository variable `IMAGE_REPO` |
| Our manifests are applied by an Argo CD Application that points at this repository | whether it must instead go through `cisl-cloud-charts` | `deploy/argocd/application.example.yaml` (or copy the overlay into their repository) |
| The site is reachable from the public internet over https | stations and Pi gateways upload from the field | the `ingress` component; if it is VPN-only, uploads from the field cannot work |
| Hostname `openiotwx.example.org`, ingress class `nginx` | the real hostname, class and certificate setup | overlay patch on the Ingress, and `BETTER_AUTH_URL` |
| A UTF-8 Postgres 14+ is available through `DATABASE_URL` | whether `postgres-0` can host our database, and backups | the Secret; or the `postgres` component |
| TimescaleDB is optional | whether the shared Postgres has it | nothing (without it readings are an ordinary table) |
| Secrets are created outside git | which mechanism the cluster uses (sealed-secrets, external-secrets, ...) | whatever creates `openiotwx` |
| Namespace `openiotwx`, 2 replicas, 200m to 1 CPU and 384Mi to 1Gi per pod | quotas | `base/deployment.yaml` or a patch |
| Pods may run as uid 1000 with a read-only filesystem | the namespace's pod security level | `base/deployment.yaml` (it is already the strictest common setting) |
| Sign-in is the site's own email and password | whether UCAR single sign-on should be used | not built; a later change |
| The chat's language model is off | whether the cluster's `ollama-server` may be used | overlay: `CHAT_LLM_ENDPOINT`, `CHAT_LLM_MODEL` |
| Forecasts: the built-in stand-in only | whether the CREDIT results in the cluster can be read | later |
| MQTT is not used | whether the cluster's `mosquitto` should feed the site | later (the bridge script exists: `scripts/mqtt-bridge.mjs`) |

## Not covered yet

- Email verification and password reset (they need an outgoing mail server).
- Single sign-on for administrators.
- Metrics and alerting. The pods log to standard output and answer `/api/health`; wire those into the cluster's monitoring.

## Deploy it ourselves (kubectl, no vault, no Argo CD)

Used for the first deployment on `nwc1`. The account may create secrets, volumes, jobs and ingresses in its own namespace, so
everything in `deploy/k8s/overlays/cirrus` can be applied by hand, except the three vault objects. The overlay
`deploy/k8s/overlays/cirrus-direct` is that overlay with those three objects removed.

1. Sign in: `$env:KUBECONFIG = "$HOME\.kube\cirrus-config"`, kubelogin on the PATH, `kubectl config use-context nwc1` (VPN needed).
2. Create the two Secrets (the database password must be the same in both; keep a copy somewhere safe, outside git):

   ```
   kubectl -n openiotwx create secret generic openiotwx-db --from-literal=POSTGRES_PASSWORD='<password>'
   kubectl -n openiotwx create secret generic openiotwx --from-literal=BETTER_AUTH_SECRET='<32+ characters>' \
     --from-literal=DATABASE_URL='postgres://iotwx:<password>@openiotwx-db:5432/iotwx'
   ```

3. Check, then apply: `kubectl apply -k deploy/k8s/overlays/cirrus-direct --dry-run=server`, then the same without `--dry-run`.
4. Watch: `kubectl -n openiotwx get pods`, `kubectl -n openiotwx logs job/openiotwx-migrate`, then `/api/health` on the public address.
5. First administrator (after that person has signed up on the site):
   `kubectl -n openiotwx exec deploy/openiotwx -- node scripts/make-admin.mjs person@example.org superadmin`.

Lessons from the first run on CIRRUS:

- **Image names must be complete.** The nodes refuse short names such as `timescale/timescaledb` ("short name mode is enforcing")
  and the pod stays in `ImageInspectError`. Use `docker.io/timescale/timescaledb:...`.
- **A StatefulSet pod that never became ready is not replaced by an update.** After fixing the template, delete that pod.
- **The migration Job gives up after its retries.** If the database was late, delete the Job and apply again.
- **Storage:** `ceph-kubepv` (block storage, one pod at a time). A StatefulSet cannot change it later.
- **The hostname needs a DNS record** pointing at the Traefik address that `kubectl -n openiotwx get ingress` shows. The certificate is
  issued without it, but nobody can reach the site by name until the record exists.
- **Passwords are only in the cluster.** If the Secret `openiotwx-db` is deleted, the password of the existing database is lost;
  keep a copy.
