# DeltaForge on Azure: "Plan B" per-slot autoscaler pool

These templates package DeltaForge for Azure Marketplace, one Bicep template per
license tier, using the **Plan B slot-pool** compute model.

## The model

The platform Container App runs the control plane plus a single always-on
embedded compute node. Instead of scaling a compute sidecar inside that app, the
template **pre-creates `slotCount` standalone compute Container Apps**
(`compute-1` .. `compute-N`), each parked at `minReplicas = 0`. A parked slot
runs nothing and costs nothing.

When demand arrives, the control-plane autoscaler flips a slot from `0` to `1` by
editing that slot app's `minReplicas` through the Azure Resource Manager REST
API. When the slot drains, the autoscaler flips it back to `0`. Each slot has its
own external managed-TLS FQDN (`compute-N.<env-default-domain>`) and is
direct-dialed by clients; the control plane is a directory and load balancer,
never a data-path proxy.

This replaces the in-app compute sidecar (the old `8001` port mapping and the
`compute` container in `containerapps.bicep`). The platform still exposes:

- `443` (web bridge): the browser console.
- `3000` (control-plane API): where clients fetch the node list and recommend a
  node.

The data path is the slots, each on its own FQDN over `443`.

## Files

| File | Role |
| --- | --- |
| `modules/slot-pool.bicep` | The ONE shared implementation: platform + PostgreSQL + Blob + NFS storage + Key Vault + managed environment + system-assigned managed identity + the slot loop + the autoscaler env + the role grants. Parameterized by `tier` and `slotCount`. |
| `community.bicep` | Thin wrapper. `tier = community`, `slotCount = 1`. |
| `standard.bicep` | Thin wrapper. `tier = standard`, `slotCount = 4`. |
| `professional.bicep` | Thin wrapper. `tier = professional`, `slotCount = 9`. |

The three wrappers contain no infrastructure of their own: each sets the two tier
constants and forwards every other parameter into `modules/slot-pool.bicep`. The
implementation body is never copied per tier (single code path).

## Per-tier slot counts (and why)

`slotCount` is the tier's license **node ceiling minus the one always-on embedded
node** that runs inside the platform app. The embedded node already counts
against the license ceiling, so the pool only needs to cover the remainder.

| Tier | License node ceiling | Embedded node | `slotCount` |
| --- | --- | --- | --- |
| Community | 2 | 1 | 1 |
| Standard | 5 | 1 | 4 |
| Professional | 10 | 1 | 9 |

Bicep cannot read the license at deploy time, so each tier's ceiling is a
constant baked into the wrapper. The platform also publishes the ceiling to its
autoscaler as `DELTA_FORGE_SCALING_MAX_NODES = slotCount` (see below), so the
autoscaler never tries to flip a slot that does not exist.

## The autoscaler env (read at platform boot)

`modules/slot-pool.bicep` sets these on the platform container. They are read at
boot by `seed_scaling_config_from_env` in
`delta-forge-control/src/api/scaling_config.rs`, which seeds the Azure
provisioner when the persisted config is still `Off`. The names match that
function exactly.

| Env var | Value |
| --- | --- |
| `DELTA_FORGE_SCALING_BACKEND` | `azure` |
| `DELTA_FORGE_SCALING_SUBSCRIPTION_ID` | `subscription().subscriptionId` |
| `DELTA_FORGE_SCALING_RESOURCE_GROUP` | `resourceGroup().name` |
| `DELTA_FORGE_SCALING_MIN_NODES` | `0` (scale-to-zero) |
| `DELTA_FORGE_SCALING_MAX_NODES` | `slotCount` |
| `DELTA_FORGE_SCALING_CREDENTIAL_REF` | the `scalingCredentialRef` parameter (default empty; see the optional service-principal step) |

The slot pool is **auto-discovered**, so the template passes no explicit slot
list. At each scaling action the platform lists the Container Apps in
`DELTA_FORGE_SCALING_RESOURCE_GROUP` and selects those tagged
`deltaforge-role=compute-slot` (every slot app carries that tag). Adding or
removing a slot therefore needs no env change or redeploy. The discovery list
query uses the same ARM identity + Contributor grant the replica flip uses
(Contributor includes `Microsoft.App/containerApps` read). Two optional
overrides, read by `seed_scaling_config_from_env`:

| Env var | Value |
| --- | --- |
| `DELTA_FORGE_SCALING_SLOT_APPS` | comma-joined slot names. A non-empty list **pins** the pool and overrides discovery (restricted-RBAC / air-gapped). |
| `DELTA_FORGE_SCALING_DISCOVER_SLOTS` | `true`/`false` to force discovery on or off explicitly. Default: on when no `SLOT_APPS` list is supplied. |

No secret is passed through env. By default `DELTA_FORGE_SCALING_CREDENTIAL_REF`
is empty and the provisioner authenticates to ARM with the platform's ambient
managed identity (the system-assigned identity granted Contributor below). If you
choose to use a service principal instead, its secret lives in the platform vault
and is referenced by `DELTA_FORGE_SCALING_CREDENTIAL_REF`. This is the same
secrets methodology the GUI uses: the config holds a reference, never the value.

Each slot app sets `NODE_ID = worker::compute-N`. The control plane uses that to
map a drained node back to its slot app so it can flip the right one off.

## Role grant: why the platform needs Contributor on the resource group

To flip a slot's `minReplicas` through ARM, the platform's system-assigned
managed identity needs write access to the slot Container Apps. The template
grants it **Contributor** (`b24988ac-6180-42a0-ab88-20f7382dd24c`) at
`resourceGroup()` scope, which is where the platform and every slot app live.
This grant is in `modules/slot-pool.bicep` (`contributorRole`).

## No post-deploy step required (managed identity is the default)

The template wires everything the autoscaler needs. By default the provisioner
authenticates to ARM with the platform's **ambient managed identity**: the
system-assigned identity that the template grants Contributor on the resource
group. `DELTA_FORGE_SCALING_CREDENTIAL_REF` is empty out of the box, so the
provisioner reads an ARM bearer token from the Container Apps managed-identity
endpoint (`IDENTITY_ENDPOINT` / `IDENTITY_HEADER`, falling back to the
`169.254.169.254` IMDS endpoint) and flips slot `minReplicas` with no stored
secret. This is the Azure analogue of the AWS task IAM role and the GCP runtime
service account. The code path is `azure_imds_token` /
`AzureAuth::ManagedIdentity` in `delta-forge-control/src/api/provisioner.rs`,
selected when no `credentialRef` resolves.

### Optional: use a service principal instead of the managed identity

If your environment cannot use the ambient managed identity (for example you want
the provisioner to authenticate as a dedicated, separately-auditable identity),
you can supply a service principal instead. This is optional; skip it unless you
have a reason to.

1. **Create a service principal and give it Contributor on the resource group.**
   `az ad sp create-for-rbac` does both in one call (set the scope to the resource
   group the deployment landed in):

   ```bash
   az ad sp create-for-rbac \
     --name "deltaforge-autoscaler" \
     --role Contributor \
     --scopes "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>"
   # captures: appId (clientId), password (clientSecret), tenant (tenantId)
   ```

2. **Store the SP credential in the platform vault** as a single JSON value,
   `{ "tenantId": "...", "clientId": "...", "clientSecret": "..." }`, mapping
   `tenant` -> `tenantId`, `appId` -> `clientId`, `password` -> `clientSecret`
   from the previous step. Create the vault entry with the CLI
   (`deltaforge vault create ...`, which calls `POST /api/v1/vault/entries`) or
   any admin client; the call returns the entry id.

3. **Point `DELTA_FORGE_SCALING_CREDENTIAL_REF` at that vault entry id** and
   re-apply (pass `scalingCredentialRef` to the template, or update the running
   platform app's env and let it re-seed). When the reference resolves, the
   provisioner authenticates as the service principal
   (`AzureAuth::ServicePrincipal`) instead of the managed identity. If the
   reference is set but cannot be resolved or parsed, the provisioner refuses to
   flip slots (observe-only) rather than silently falling back; leave the
   reference empty to use the managed identity.

You can also configure scaling over the admin API
(`PUT /api/v1/admin/scaling/config`, exposed by the CLI as `deltaforge scaling
set`) instead of through the env seed.
