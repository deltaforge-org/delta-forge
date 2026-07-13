# DeltaForge on Azure (Bicep)

Spin up a single-node DeltaForge in minutes: one platform container, a managed
PostgreSQL Flexible Server for the catalog, and a file share for persistent
config / git workspace clones / zone storage.

```
┌──────────────────────────── resource group ────────────────────────────┐
│                                                                         │
│  Azure Container Instance            Azure Database for PostgreSQL       │
│  (platform image)                    Flexible Server                     │
│   - control plane  :3000  ───────────►  catalog DB  (TLS, sslmode=require)│
│   - embedded compute                                                    │
│   - web bridge     :3031                                                │
│        │                                                                │
│        └── /data  ──►  Storage account file share                       │
│                        (config.toml, repo clones, zone data)            │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- `az login` to the target subscription.
- A DeltaForge license key.
- Access to the platform image. The default `ghcr.io/deltaforge-org/platform`
  is public, so the registry params can be left empty and the image pulls with no
  credentials. For a private or ACR image, set `registryServer` and supply
  `registryUsername` / `registryPassword`.

## Deploy

```bash
# 1. Copy and fill in the parameters (license, passwords, registry creds)
cp deploy/azure/main.parameters.example.json deploy/azure/main.parameters.json
$EDITOR deploy/azure/main.parameters.json

# 2. Create a resource group
az group create -n rg-deltaforge -l westeurope

# 3. Deploy
az deployment group create \
  -g rg-deltaforge \
  -f deploy/azure/main.bicep \
  -p @deploy/azure/main.parameters.json

# 4. Read the console URL from the outputs
az deployment group show -g rg-deltaforge -n main \
  --query properties.outputs.consoleUrl.value -o tsv
```

First boot runs the non-interactive headless bootstrap (provisions the catalog
schema in PostgreSQL, seeds the admin/engineer accounts, activates the license).
Give it a couple of minutes, then browse to the `consoleUrl` output.

## Tear down everything

```bash
az group delete -n rg-deltaforge --yes
```

That removes the container, PostgreSQL server, storage account, and all data.

## API over HTTPS (`enableHttps`)

The DeltaForge binary serves the API over plain HTTP (TLS termination is expected
at the edge). The template fronts it with a **Caddy sidecar** in the same
container group that terminates HTTPS and reverse-proxies to the control plane on
`localhost:3000`. With `enableHttps=true` (the default) the group exposes only
`443` (HTTPS) and `80` (which 308-redirects to HTTPS); the raw `3000`/`3031`
ports are no longer public.

Certificate behaviour:

- **`customDomain` set** (recommended for production): Caddy uses public ACME
  (Let's Encrypt) for a **trusted** certificate. Point the domain's DNS at the
  container group's public IP after the first deploy.
- **`customDomain` empty** (the `*.azurecontainer.io` FQDN): public ACME would
  hit Let's Encrypt rate limits on that shared domain, so Caddy uses its
  **internal CA** instead. HTTPS is real (encrypted), but the certificate is
  self-signed, so browsers/clients warn unless they trust it (`curl -k`).

Set `enableHttps=false` only for plain-HTTP **dev** (no certificate needed); for
Azure, keep it `true`. The Caddy image is read from `caddyImage` (default Docker
Hub); mirror it into your registry to avoid Docker Hub pull limits.

## Postgres TLS / SSL

Azure PostgreSQL enforces SSL by default, and DeltaForge's connection pool
negotiates TLS from the DSN's `sslmode` (see
`delta_forge_bootstrap::provision::pool_from_dsn`). The template therefore keeps
SSL **on** and connects with `sslmode=require` out of the box. No server-side
weakening is required.

`disableDbSsl=true` exists only as an escape hatch for an **older image whose
connection pool predates TLS support** (it connects with `NoTls`). Setting it
flips the server's `require_secure_transport` OFF and switches the DSN to
`sslmode=disable`. Leave it `false` for any current image.

## Notes and limits

- **Why external PostgreSQL:** the embedded/managed PostgreSQL the desktop build
  ships does not initialise inside the slim server container and cannot run on an
  SMB (Azure File) volume. External PostgreSQL via `DELTA_FORGE_DB_URL` is the
  supported cloud topology. With it, `/data` holds only ordinary files, which are
  SMB-safe.
- **Public endpoint:** the container gets a public IP/FQDN and the PostgreSQL
  firewall allows Azure services only (not the public internet). Put the control
  plane behind your own ingress/TLS for anything beyond a test.
- **Scaling out:** this is a single platform node. Add compute workers later by
  running the `compute` image with `CONTROL_PLANE_URL` pointed at this node; see
  `deploy/README.md` and `deploy/kubernetes/`.
- **Password encoding:** `pgAdminPassword` is embedded in the DSN, so use
  URL-safe characters (letters and digits).
