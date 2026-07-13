# DeltaForge on GCP (Terraform)

Single-node DeltaForge on Google Cloud, the analogue of [`deploy/azure`](../azure)
and [`deploy/aws`](../aws). One `terraform apply` provisions and bootstraps
everything with no manual steps:

```
┌──────────────────────────── project ────────────────────────────────────────┐
│                                                                              │
│  Compute Engine VM (Ubuntu + Docker)        Cloud SQL for PostgreSQL          │
│   ├─ platform  :3000 control plane ──────►  catalog DB (TLS, sslmode=require) │
│   │            :3031 console/web bridge                                       │
│   ├─ caddy     :443/:80 terminates HTTPS, proxies → localhost:3031            │
│   ├─ persistent disk  /data  (config + git workspace clones + engine state)   │
│   └─ static external IP  (stable address for DNS / certs)                     │
│        │                                                                      │
│        └─ GCS bucket   (Delta/zone table data; via the VM service account)     │
│                                                                              │
│  Secret Manager: license, admin/engineer passwords, DB URL                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

The Platform serves its web console on the same origin as the API. Storage auth
is keyless: the VM's **service account** has `storage.objectAdmin` on the bucket
and the engine reaches GCS via Application Default Credentials
(`GoogleCloudStorageBuilder::from_env` → the metadata server), so no service
account keys are written anywhere. Secrets live in Secret Manager and are fetched
at boot by the VM service account; they never land in instance metadata.
Entitlement is the DeltaForge **license key** (DeltaForge meters itself); there is
no GCP Marketplace metering wiring.

## Prerequisites

- A GCP project and `gcloud auth application-default login` (or a Terraform
  service account) with rights to create the resources below.
- Terraform >= 1.5.
- A DeltaForge license key.
- The platform image somewhere the VM can pull it: Artifact Registry
  (recommended), a public image, or a private registry via `registry_credentials`.

## Deploy

```bash
cd deploy/gcp/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars         # project_id, license_key, emails, image

terraform init
terraform apply

terraform output console_url
```

First boot installs Docker, mounts the data disk, fetches secrets, and runs the
platform container, which then runs the non-interactive headless bootstrap
(catalog schema, seeded accounts, license activation). Give it a few minutes
(the VM also does a one-time `apt-get install`), then browse to `console_url`.
Auto-generated passwords are in the `admin_password` / `engineer_password`
outputs (`terraform output -raw admin_password`) and in Secret Manager.

### HTTPS (`enable_https`, default true)

A Caddy sidecar terminates TLS (mirrors the Azure/AWS templates).

- **`custom_domain` set**: Caddy uses public ACME (Let's Encrypt) for a trusted
  cert. After the first apply, point the domain's DNS **A record** at the
  `instance_ip` output.
- **`custom_domain` empty**: Caddy uses its internal CA against the static IP.
  HTTPS is real but self-signed, so clients warn unless they trust it (`curl -k`).

## Tear down

```bash
terraform destroy
```

The GCS bucket has `force_destroy = false`, so a non-empty bucket blocks destroy;
empty it (or flip the flag) for a full wipe.

## Why a VM (and not Cloud Run)

The VM mirrors the Azure ACI model exactly: a stable IP, two containers, and a
real POSIX `/data` on a persistent disk for the engine's instance/activation
state and signing keys. **Cloud Run** is a valid alternative (managed TLS, no
Caddy, native Secret Manager + Cloud SQL integration) and is also Marketplace-
eligible, but its request-scoped model and the GCS-FUSE `/data` mount are a worse
fit for the always-on scheduler/compute workers and the engine's lock/rename file
semantics. Use the VM for a faithful, robust single-node deployment.

## GCP Marketplace

GCP Marketplace accepts **Terraform** (and Deployment Manager) as a deployment
method, so this module is the deployment artifact directly: `variables.tf` is the
launch form. No marketplace **metering** is wired (entitlement is the license
key), so this is a "bring your own license" listing, not a metered offer.

## Notes / knobs

- `machine_type` defaults to `e2-standard-4`; `db_tier` to `db-custom-1-3840`.
- SSH is reachable only via Identity-Aware Proxy (`35.235.240.0/20`), not the
  public internet.
- The bucket URL (`tables_bucket_zone_root`, `gs://...`) is what you use when
  creating a zone in the console; it is an output, not baked into the engine.
