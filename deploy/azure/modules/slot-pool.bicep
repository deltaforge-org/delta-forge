// DeltaForge on Azure - "Plan B" per-slot autoscaler pool.
//
// This is the ONE shared implementation behind the per-tier Marketplace
// wrappers (community.bicep, standard.bicep, professional.bicep). Each wrapper
// sets only `tier` and `slotCount` and instantiates this module; the body is
// never copied per tier (single code path).
//
// The model (Plan B slot pool):
//   - The Platform Container App runs the control plane + the always-on embedded
//     compute node, exactly the infra of containerapps.bicep (PostgreSQL flexible
//     server, Blob + NFS storage, Key Vault, VNet-integrated managed environment,
//     system-assigned managed identity).
//   - Instead of an in-app compute sidecar, this template pre-creates `slotCount`
//     standalone "slot" compute Container Apps (compute-1 .. compute-N), each idle
//     at minReplicas=0 (so $0 when cold). Each slot has its own external managed
//     -TLS FQDN and is direct-dialed by clients.
//   - The platform's control-plane autoscaler flips a slot 0->1 on demand by
//     editing that slot app's minReplicas through the Azure Resource Manager REST
//     API. For the platform's system-assigned identity to do that it is granted
//     Contributor on the resource group below.
//
// Why no 8001 mapping / no `compute` sidecar (vs containerapps.bicep): the slot
// pool REPLACES the single in-app compute node. The platform still exposes the
// control-plane API on 3000 (clients ask it for the node list); the data path is
// the slots, each on its own FQDN over 443.

// =============================== Tier / pool ================================
@description('License tier this template is packaged for (community | standard | professional). Informational; drives resource tags only.')
param tier string

@description('Number of pre-created compute slots in the pool (the license node ceiling minus the 1 always-on embedded node on the platform).')
@minValue(1)
@maxValue(64)
param slotCount int

// =============================== Core =======================================
@description('Location for all resources.')
param location string = resourceGroup().location

@description('Short prefix for resource names. Lowercase letters and digits.')
@minLength(3)
@maxLength(16)
param namePrefix string = 'deltaforge'

@description('DeltaForge Platform container image. Defaults to the published public image; override only for a private/air-gapped registry.')
param image string = 'ghcr.io/deltaforge-org/deltaforge-platform:latest'

@description('DeltaForge Compute (worker) container image run by every slot in the pool. Defaults to the published public image.')
param computeImage string = 'ghcr.io/deltaforge-org/deltaforge-compute:latest'

@description('DeltaForge GUI container image (browser GUI, HTTP-serving headless mode) for the dedicated GUI app. Defaults to the published public image.')
param guiImage string = 'ghcr.io/deltaforge-org/deltaforge-gui:latest'

@description('Deploy the client apps (GUI + compute slots). Staged-deploy gate: deploy once with false (Postgres + the authoritative server only), wait for the server to finish bootstrapping the shared catalog, then deploy again with true to bring up the GUI and compute slots against a seeded database. ARM dependsOn orders resource CREATION but not runtime READINESS, so this gate is what enforces pg -> server-bootstrapped -> gui/compute.')
param deployClients bool = true

@description('Shared secret the compute slots register with (NODE_SECRET). Auto-generated per deployment; no need to supply one.')
@secure()
param computeNodeSecret string = newGuid()

@description('Private registry login server (e.g. <acr>.azurecr.io). Leave empty to pull the default public images.')
param registryServer string = ''
@description('Private registry username. Only needed when registryServer is set.')
param registryUsername string = ''
@description('Private registry password / token. Only needed when registryServer is set.')
@secure()
param registryPassword string = ''

@description('Root init image (chowns the NFS /data mount for the non-root engine). Microsoft Container Registry, no Docker Hub rate limit.')
param initImage string = 'mcr.microsoft.com/azurelinux/base/core:3.0'

@description('vCPU for the Platform container (Consumption: 0.25-4).')
param cpuCores string = '2.0'
@description('Memory for the Platform container (e.g. 4Gi). Must pair with cpuCores.')
param memory string = '4Gi'

@description('vCPU for each compute slot container (Consumption: 0.25-4).')
param slotCpuCores string = '2.0'
@description('Memory for each compute slot container (e.g. 4Gi). Must pair with slotCpuCores.')
param slotMemory string = '4Gi'

// =========================== Seeded accounts ================================
@description('Seeded admin account email.')
param adminEmail string = 'admin@deltaforge.local'
@description('Seeded engineer account email.')
param engineerEmail string = 'engineer@deltaforge.local'
@description('DeltaForge license key. Leave empty to auto-provision a Community license on first boot: the platform exchanges its managed-identity token with the DeltaForge console (subscription-attested), so a Marketplace buyer needs no pre-obtained key. Supply a key only to pin a purchased/higher tier.')
@secure()
param licenseKey string = ''

@description('DeltaForge console (license service) base URL used for subscription-attested auto-provisioning when no licenseKey is supplied.')
param consoleUrl string = 'https://console.deltaforge.org'

// Passwords are supplied by the caller (generated by the deploy script with a
// real password algorithm). Bicep has no random_password primitive.
@secure()
param adminPassword string
@secure()
param engineerPassword string
@secure()
param pgAdminPassword string

// =============================== PostgreSQL =================================
param pgAdminUser string = 'dfadmin'
param pgSkuName string = 'Standard_B1ms'
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param pgTier string = 'Burstable'
param pgStorageGb int = 32
param pgVersion string = '16'

// =============================== Storage ====================================
@description('Premium NFS file share size (GiB) for /data. Premium minimum is 100.')
@minValue(100)
@maxValue(102400)
param dataShareGb int = 100

// ============================== Mailer (SMTP) ===============================
param smtpHost string = ''
param smtpPort int = 587
param smtpUsername string = ''
@secure()
param smtpPassword string = ''
param mailFrom string = ''
param mailFromName string = 'DeltaForge'
param smtpStartTls bool = true

// =========================== Scaling credential =============================
@description('Vault entry id holding the Azure service-principal credential the provisioner uses to flip slot minReplicas via ARM. Empty at deploy time: the operator creates the SP + vault entry post-deploy (see README-slot-pool.md) and re-applies. Wired into DELTA_FORGE_SCALING_CREDENTIAL_REF.')
param scalingCredentialRef string = ''

// ============================ Derived names =================================
// Names are READABLE and deploy-scoped. The instance stem comes from the resource
// group name (e.g. 'deltaforge-t11' -> 'dft11'), so every object says at a glance
// WHICH deployment and WHAT role it is (dft11blob…, dft11nfs…, dft11kv…, dft11dskv…,
// dft11-pg-…) instead of an opaque hash. Globally-unique cross-tenant DNS names
// (storage accounts, Key Vaults, PostgreSQL) still carry a uniqueness token derived
// from uniqueString(resourceGroup().id) so two installs never collide across tenants,
// but it is trimmed to 6 chars (from 13) so the readable stem dominates. `take`
// clamps each to Azure's length limit (storage + Key Vault are 24 chars; storage
// allows no hyphens — `instance` and `uniq` are already hyphen-free + lowercased).
var suffix = uniqueString(resourceGroup().id)
var instance = toLower(replace(replace(resourceGroup().name, 'deltaforge-', 'df'), '-', ''))
var uniq = substring(suffix, 0, 6)
var pgServerName = toLower('${instance}-pg-${uniq}')
var blobStorageName = toLower(take('${instance}blob${uniq}', 24))
var nfsStorageName = toLower(take('${instance}nfs${uniq}', 24))
// Two Key Vaults, separated by purpose. SYSTEM vault (keyVaultName): DeltaForge's
// own secrets (Postgres/admin/engineer passwords, license, signing material),
// wired to the platform via AZURE_KEY_VAULT_URL. DATASOURCES vault (dsKeyVaultName):
// customer data-source connection credentials, referenced per credential-storage
// backend. Keeping them apart means a data-source secret breach never touches the
// platform's own keys, and vice versa.
// Key Vaults allow hyphens, so separate the parts for readability: dft11-kv-<hash>,
// dft11-dskv-<hash>. (Storage accounts above CANNOT — Azure permits only lowercase
// letters + digits there, so blob/nfs stay concatenated: dft11blob<hash>.)
var keyVaultName = toLower(take('${instance}-kv-${uniq}', 24))
var dsKeyVaultName = toLower(take('${instance}-dskv-${uniq}', 24))
var logWorkspaceName = '${namePrefix}-logs'
var envName = '${namePrefix}-env'
var serverAppName = '${namePrefix}-server'
var vnetName = '${namePrefix}-vnet'
var subnetName = '${namePrefix}-snet'
var envStorageName = 'data'
var blobContainerName = 'deltatables'
var databaseName = 'deltaforge'
var pgFqdn = '${pgServerName}.postgres.database.azure.com'
var dbDsn = 'postgres://${pgAdminUser}:${pgAdminPassword}@${pgFqdn}:5432/${databaseName}?sslmode=require'
var blobZoneRoot = 'abfss://${blobContainerName}@${blobStorageName}.dfs.${environment().suffixes.storage}'
var smtpConfigured = !empty(smtpHost)
var roleBlobContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
var roleKvSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'  // Key Vault Secrets Officer (get + LIST + set + delete; the platform hosts secrets and the backend probe lists secrets)
var roleContributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'    // Contributor (flip slot minReplicas via ARM)
// ACA TLS-terminates ONLY the main ingress (443). Clients (ODBC/ADBC/CLI) and the
// compute slots must reach the CONTROL-PLANE API (auth + /api/v1/nodes/register +
// recommend) over managed TLS, so the control-plane API (3000) is the MAIN ingress.
// The web bridge (3031: browser SPA + /api/invoke) is a plain-HTTP additional port
// (additional ports do not get the managed cert). Slots run the worker on 3031.
var cpApiPort = 3000
var ingressPort = 3031
var appFqdn = '${serverAppName}.${env.properties.defaultDomain}'
var publicUrl = 'https://${appFqdn}'
// The GUI (deltaforge binary, headless mode = HTTP only) runs as its OWN container
// app so it gets its OWN managed-TLS 443 FQDN, instead of being a plain-HTTP
// additional port on the server. ACA TLS-terminates one ingress per app, so a
// dedicated app is the only way to serve the GUI over HTTPS alongside the HTTPS
// control-plane API. The deployed name is exactly the prefix (deltaforge).
var guiAppName = namePrefix
var guiFqdn = '${guiAppName}.${env.properties.defaultDomain}'
var guiPublicUrl = 'https://${guiFqdn}'

// Slot pool addressing. Each slot is its own external Container App on the same
// managed environment, so it gets `<slot>.<env defaultDomain>` with a per-host
// managed TLS cert. The control plane direct-dials each slot at that FQDN over
// 443; the control plane is a directory / load balancer, never a data-path proxy.
//
// The autoscaler env below (DELTA_FORGE_SCALING_*) is read at platform boot by
// `seed_scaling_config_from_env` in delta-forge-control. NODE_ID on each slot is
// `worker::<slot-app-name>` so the control plane can map a drained node back to
// its slot app and flip it off. The platform does not receive an explicit slot
// list: it DISCOVERS the pool by listing apps in this resource group tagged
// `deltaforge-role=compute-slot` (see the slot apps + the Contributor grant).
var slotNames = [for i in range(0, slotCount): '${namePrefix}-compute-${i + 1}']

// =============================== Networking =================================
// Container Apps NFS requires a VNet-integrated environment; the subnet is
// delegated to the environment and carries a Storage service endpoint so the
// Premium NFS account can be locked to this VNet.
resource vnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/16' ] }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.20.0.0/23'
          delegations: [
            { name: 'aca', properties: { serviceName: 'Microsoft.App/environments' } }
          ]
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
    ]
  }
}

// =============================== PostgreSQL =================================
resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: pgServerName
  location: location
  sku: { name: pgSkuName, tier: pgTier }
  properties: {
    version: pgVersion
    administratorLogin: pgAdminUser
    administratorLoginPassword: pgAdminPassword
    storage: { storageSizeGB: pgStorageGb }
    network: { publicNetworkAccess: 'Enabled' }
    highAvailability: { mode: 'Disabled' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
  }
}
// The three PG children are explicitly SERIALIZED (firewall -> database ->
// configuration). They are siblings, so ARM would otherwise create them in
// parallel, and PostgreSQL Flexible Server rejects concurrent management
// operations on one server with "ServerIsBusy: Cannot complete operation
// while server ... is busy processing another operation" (failed a t12
// provision; earlier deploys just won the timing race).
resource pgFirewallAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: pg
  name: 'AllowAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}
resource pgDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: pg
  name: databaseName
  properties: { charset: 'UTF8', collation: 'en_US.utf8' }
  dependsOn: [ pgFirewallAzure ]
}
resource pgExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: pg
  name: 'azure.extensions'
  properties: { value: 'btree_gist', source: 'user-override' }
  dependsOn: [ pgDatabase ]
}

// ========================= Blob storage (table data) =======================
resource blobStorage 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: blobStorageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  // isHnsEnabled = ADLS Gen2 (hierarchical namespace). DeltaForge addresses
  // tables over abfss:// and relies on real directory semantics, so the account
  // MUST be Gen2, not a flat Blob (Gen1-style) account. This flag is immutable
  // after creation, so a flat account can never be upgraded in place.
  properties: { minimumTlsVersion: 'TLS1_2', allowBlobPublicAccess: false, isHnsEnabled: true }
}
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2026-04-01' = {
  parent: blobStorage
  name: 'default'
}
resource tablesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-04-01' = {
  parent: blobService
  name: blobContainerName
  properties: { publicAccess: 'None' }
}

// ===================== Premium NFS storage (/data disk) =====================
// FileStorage (premium) is required for NFS shares. NFS is not encrypted in
// transit, so secure-transfer is off and the account is locked to the VNet.
resource nfsStorage 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: nfsStorageName
  location: location
  sku: { name: 'Premium_LRS' }
  kind: 'FileStorage'
  properties: {
    supportsHttpsTrafficOnly: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: [
        { id: '${vnet.id}/subnets/${subnetName}', action: 'Allow' }
      ]
    }
  }
}
resource nfsFileService 'Microsoft.Storage/storageAccounts/fileServices@2026-04-01' = {
  parent: nfsStorage
  name: 'default'
}
resource nfsShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2026-04-01' = {
  parent: nfsFileService
  name: envStorageName
  properties: {
    enabledProtocols: 'NFS'
    rootSquash: 'NoRootSquash'
    shareQuota: dataShareGb
  }
}

// =============================== Key Vault ==================================
resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}
// Datasources Key Vault: holds customer data-source connection secrets, kept
// separate from the System vault above. Same RBAC + soft-delete posture; no
// seeded secrets (those are written when users configure connections).
resource dsKeyVault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: dsKeyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}
resource kvPgPassword 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: keyVault
  name: 'deltaforge-postgres-password'
  properties: { value: pgAdminPassword }
}
resource kvAdminPassword 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: keyVault
  name: 'deltaforge-admin-password'
  properties: { value: adminPassword }
}
resource kvEngineerPassword 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: keyVault
  name: 'deltaforge-engineer-password'
  properties: { value: engineerPassword }
}
resource kvLicense 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: keyVault
  name: 'deltaforge-license-key'
  properties: { value: licenseKey }
}

// ====================== Log Analytics + environment ========================
resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: logWorkspaceName
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource env 'Microsoft.App/managedEnvironments@2026-01-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logWorkspace.properties.customerId
        sharedKey: logWorkspace.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    vnetConfiguration: {
      infrastructureSubnetId: '${vnet.id}/subnets/${subnetName}'
      internal: false
    }
  }
}

// NFS /data mount (durable: config + git workspace clones + engine state).
resource envStorage 'Microsoft.App/managedEnvironments/storages@2026-01-01' = {
  parent: env
  name: envStorageName
  properties: {
    nfsAzureFile: {
      server: '${nfsStorageName}.file.${environment().suffixes.storage}'
      shareName: '/${nfsStorageName}/${envStorageName}'
      accessMode: 'ReadWrite'
    }
  }
  dependsOn: [ nfsShare ]
}

// ============================ Platform container app ========================
resource app 'Microsoft.App/containerApps@2026-01-01' = {
  name: serverAppName
  location: location
  tags: { 'deltaforge-tier': tier, 'deltaforge-role': 'server' }
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: cpApiPort
        transport: 'auto'
        allowInsecure: false
        traffic: [ { latestRevision: true, weight: 100 } ]
        // ACA TLS-terminates the main ingress. The control-plane API (3000) is the
        // 443 ingress so clients (ODBC/ADBC/CLI) and the compute slots reach auth +
        // /api/v1/nodes/register + recommend over managed TLS at https://<fqdn>.
        // The browser GUI runs as its OWN app (guiApp below) with its own
        // 443 FQDN, so the GUI is served over managed TLS too -- it is NOT a
        // plain-HTTP additional port here anymore. No in-app compute sidecar: the
        // slot pool (the compute-N apps below) is the data path, each on its own
        // FQDN:443.
      }
      registries: empty(registryServer) ? [] : [
        { server: registryServer, username: registryUsername, passwordSecretRef: 'acr-password' }
      ]
      secrets: concat(empty(registryServer) ? [] : [
        { name: 'acr-password', value: registryPassword }
      ], [
        { name: 'db-url', value: dbDsn }
        { name: 'admin-password', value: adminPassword }
        { name: 'engineer-password', value: engineerPassword }
        { name: 'compute-node-secret', value: computeNodeSecret }
      ], empty(licenseKey) ? [] : [
        // Only materialized when a key is supplied; an empty licenseKey means
        // the platform auto-provisions a Community license at boot (below), so
        // there is no license secret to mount. (ACA rejects empty secret values.)
        { name: 'license-key', value: licenseKey }
      ], smtpConfigured ? [
        { name: 'smtp-password', value: smtpPassword }
      ] : [])
    }
    template: {
      // Root init container: NFS share roots are root-owned, so make /data
      // writable by the non-root engine (uid/gid 65532) before it starts.
      initContainers: [
        {
          name: 'fix-data-perms'
          image: initImage
          command: [ '/bin/sh', '-c', 'chown -R 65532:65532 /data && chmod 0775 /data' ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          volumeMounts: [ { volumeName: 'data', mountPath: '/data' } ]
        }
      ]
      containers: [
        {
          name: 'server'
          image: image
          resources: { cpu: json(cpuCores), memory: memory }
          env: concat([
            { name: 'DELTA_FORGE_DB_URL', secretRef: 'db-url' }
            // The control plane's expected node-join secret. Every slot presents
            // this same value as NODE_SECRET (see the slot container env below),
            // so register_node admits a slot via the constant-time env_secret
            // match in its admission gate. Keeps the per-cluster join secret
            // distinct from the license (which stays purely the entitlement).
            { name: 'DELTA_FORGE_NODE_SECRET', secretRef: 'compute-node-secret' }
            { name: 'DELTA_FORGE_ADMIN_PASSWORD', secretRef: 'admin-password' }
            { name: 'DELTA_FORGE_ENGINEER_PASSWORD', secretRef: 'engineer-password' }
            { name: 'DELTA_FORGE_ADMIN_EMAIL', value: adminEmail }
            { name: 'DELTA_FORGE_ENGINEER_EMAIL', value: engineerEmail }
            { name: 'DELTA_FORGE_ACTIVATE_ON_BOOT', value: '1' }
            // Cloud/container mode: ACA guarantees a single active revision and the
            // catalog is external Postgres, so skip the exclusive single-instance
            // file lock on the (NFS) config dir. Otherwise a rolling revision update
            // deadlocks: the new replica can't acquire the lock the old still holds.
            { name: 'DELTA_FORGE_SKIP_INSTANCE_LOCK', value: '1' }
            { name: 'DELTA_FORGE_PUBLIC_URL', value: publicUrl }
            { name: 'AZURE_STORAGE_ACCOUNT_NAME', value: blobStorageName }
            // Path-less zones (and the demo CREATE ZONE statements) default
            // their storage under this root instead of the container's local
            // disk, so catalog tables persist in the bootstrapped storage
            // account. Read by delta_forge_io::app_paths::default_zone_storage_root.
            { name: 'DELTA_FORGE_DEFAULT_STORAGE_ROOT', value: blobZoneRoot }
            // ---- Post-deploy storage seed (read by api::storage_seed::seed_storage_zone) ----
            // The presence of DELTA_FORGE_SEED_STORAGE_ACCOUNT selects Azure mode:
            // the server idempotently creates a managed-identity Credential Storage
            // (over the datasources Key Vault), an azure_adls Connection to this
            // storage account + container, and a zone rooted at the abfss prefix.
            // Omitting the account (on-prem) seeds a single local zone with no path.
            // The platform's system-assigned MI is used ambiently, so no client id.
            { name: 'DELTA_FORGE_SEED_STORAGE_ACCOUNT', value: blobStorageName }
            { name: 'DELTA_FORGE_SEED_STORAGE_CONTAINER', value: blobContainerName }
            { name: 'DELTA_FORGE_SEED_DATASOURCES_KV', value: dsKeyVaultName }
            { name: 'DELTA_FORGE_SEED_CREDENTIAL_STORAGE', value: 'azsp' }
            { name: 'DELTA_FORGE_SEED_CONNECTION', value: 'azure_backend' }
            { name: 'DELTA_FORGE_SEED_ZONE', value: 'az' }
            // The bootstrapped Key Vault is the platform's secret store in cloud
            // (the headless container has no OS keychain). Wiring its URL here is
            // what makes the platform read/write secrets from the vault via its
            // managed identity (granted Key Vault Secrets User above). Read by
            // AzureKeyVaultStore::from_env / RuntimeEnvironment detection.
            { name: 'AZURE_KEY_VAULT_URL', value: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}' }
            // ---- Plan B autoscaler wiring (read by seed_scaling_config_from_env) ----
            // The platform drives the slot pool through ARM. Names are EXACTLY the
            // env keys delta-forge-control reads at boot. The SP secret itself is
            // NOT here: it lives in the vault, referenced by CREDENTIAL_REF.
            //
            // The slot pool is AUTO-DISCOVERED: the platform lists Container Apps in
            // this resource group carrying the `deltaforge-role=compute-slot` tag
            // (stamped on every slot app below) and flips those. So there is no
            // explicit slot list to wire here and adding/removing a slot needs no
            // redeploy. Discovery uses the same ARM identity + Contributor grant the
            // flip uses (Contributor includes containerApps READ/list). To pin an
            // explicit set instead (restricted RBAC), set DELTA_FORGE_SCALING_SLOT_APPS
            // to a CSV; a non-empty list overrides discovery.
            { name: 'DELTA_FORGE_SCALING_BACKEND', value: 'azure' }
            { name: 'DELTA_FORGE_SCALING_SUBSCRIPTION_ID', value: subscription().subscriptionId }
            { name: 'DELTA_FORGE_SCALING_RESOURCE_GROUP', value: resourceGroup().name }
            // Warm floor of one: the autoscaler never drains below a single node,
            // matching slot 0's always-on minReplicas, so the first query never
            // cold-starts. Raise per tier later when autoscale tuning lands.
            { name: 'DELTA_FORGE_SCALING_MIN_NODES', value: '1' }
            { name: 'DELTA_FORGE_SCALING_MAX_NODES', value: string(slotCount) }
            { name: 'DELTA_FORGE_SCALING_CREDENTIAL_REF', value: scalingCredentialRef }
            // ---- Subscription-attested license auto-provisioning (read by
            // delta-forge-bootstrap::registration::provision_license_from_azure) ----
            // When DELTA_FORGE_LICENSE_KEY is absent (empty licenseKey param),
            // bootstrap fetches this platform's managed-identity ARM token and
            // exchanges it at DELTA_FORGE_CONSOLE_URL/v1/azure/provision, which
            // proves control of this subscription against ARM and returns a
            // Community license. Subscription id + resource group come from the
            // DELTA_FORGE_SCALING_* pair above (the bootstrap falls back to them);
            // the tenant id is informational. No effect when a licenseKey IS set.
            { name: 'DELTA_FORGE_CLOUD', value: 'azure' }
            { name: 'DELTA_FORGE_CONSOLE_URL', value: consoleUrl }
            { name: 'DELTA_FORGE_AZURE_TENANT_ID', value: subscription().tenantId }
          ], empty(licenseKey) ? [] : [
            { name: 'DELTA_FORGE_LICENSE_KEY', secretRef: 'license-key' }
          ], smtpConfigured ? [
            { name: 'DELTA_FORGE_MAIL_PROVIDER', value: 'smtp' }
            { name: 'DELTA_FORGE_MAIL_FROM', value: empty(mailFrom) ? smtpUsername : mailFrom }
            { name: 'DELTA_FORGE_MAIL_FROM_NAME', value: mailFromName }
            { name: 'DELTA_FORGE_SMTP_HOST', value: smtpHost }
            { name: 'DELTA_FORGE_SMTP_PORT', value: string(smtpPort) }
            { name: 'DELTA_FORGE_SMTP_USERNAME', value: smtpUsername }
            { name: 'DELTA_FORGE_SMTP_STARTTLS', value: smtpStartTls ? 'true' : 'false' }
            { name: 'DELTA_FORGE_SMTP_PASSWORD', secretRef: 'smtp-password' }
          ] : [])
          volumeMounts: [ { volumeName: 'data', mountPath: '/data' } ]
        }
      ]
      volumes: [
        { name: 'data', storageType: 'NfsAzureFile', storageName: envStorageName }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [ pgFirewallAzure, pgDatabase, pgExtensions, tablesContainer, envStorage ]
}

// ============================ GUI app (deltaforge) =========================
// The browser GUI as an INDEPENDENT container app on its OWN managed-TLS 443
// FQDN. It runs the same image as a PASSIVE control plane (no scheduler /
// autoscaler / executor -- the platform app is the single active manager) and its
// 443 ingress targets the web bridge port, so the SPA + /api/invoke are served
// over HTTPS. It shares the same Postgres + Key Vault + storage as the platform,
// so auth, catalog browsing, and query forwarding to the compute slots all work
// from the same state. No NFS volume: the GUI is passive, its durable state
// lives in Postgres / Blob / Key Vault, and /data is container-local scratch.
resource guiApp 'Microsoft.App/containerApps@2026-01-01' = if (deployClients) {
  name: guiAppName
  location: location
  tags: { 'deltaforge-tier': tier, 'deltaforge-role': 'gui' }
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: ingressPort
        transport: 'auto'
        allowInsecure: false
        traffic: [ { latestRevision: true, weight: 100 } ]
      }
      registries: empty(registryServer) ? [] : [
        { server: registryServer, username: registryUsername, passwordSecretRef: 'acr-password' }
      ]
      secrets: concat(empty(registryServer) ? [] : [
        { name: 'acr-password', value: registryPassword }
      ], [
        { name: 'db-url', value: dbDsn }
        { name: 'admin-password', value: adminPassword }
        { name: 'engineer-password', value: engineerPassword }
      ], empty(licenseKey) ? [] : [
        // Passive GUI: only mounts a license secret when one is supplied. With
        // auto-provisioning (empty licenseKey) the GUI simply runs Unlicensed /
        // Community (resource-gated, all features), which matches the tier the
        // platform provisions; the authoritative platform enforces entitlement.
        { name: 'license-key', value: licenseKey }
      ], smtpConfigured ? [
        { name: 'smtp-password', value: smtpPassword }
      ] : [])
    }
    template: {
      containers: [
        {
          name: 'gui'
          image: guiImage
          resources: { cpu: json(cpuCores), memory: memory }
          env: concat([
            { name: 'DELTA_FORGE_DB_URL', secretRef: 'db-url' }
            { name: 'DELTA_FORGE_ADMIN_PASSWORD', secretRef: 'admin-password' }
            { name: 'DELTA_FORGE_ENGINEER_PASSWORD', secretRef: 'engineer-password' }
            { name: 'DELTA_FORGE_ADMIN_EMAIL', value: adminEmail }
            { name: 'DELTA_FORGE_ENGINEER_EMAIL', value: engineerEmail }
            // Passive: this app never manages nodes; the platform app is the single
            // active control plane (scheduler / autoscaler / executor). The GUI
            // only serves the GUI + a read-mostly catalog API over the shared DB.
            { name: 'DELTA_FORGE_PASSIVE_CONTROL_PLANE', value: '1' }
            { name: 'DELTA_FORGE_ACTIVATE_ON_BOOT', value: '0' }
            { name: 'DELTA_FORGE_COMPUTE_AUTOSPAWN', value: '0' }
            // Route compute-node SELECTION (recommend + reservation) to the
            // AUTHORITATIVE control plane (deltaforge-server), not this passive
            // GUI control plane. Only deltaforge-server runs the provisioner /
            // autoscaler, so only it can warm a scaled-to-zero slot; a recommend
            // answered here would 503 (no_healthy_nodes) on a cold pool. The bridge
            // uses the user's own df_ session token against it (shared-catalog
            // session, valid on either control plane). 443 / FQDN, no port. Read by
            // resolve_auto_node in delta-forge-webapi. The server app leaves this
            // unset (it IS the authoritative CP, reached on loopback).
            { name: 'DELTA_FORGE_PUBLIC_URL', value: guiPublicUrl }
            // Thin-client mode: the GUI proxies every /api/invoke op (auth,
            // catalog, query recommend+forward) to the SERVER's control plane,
            // not its own. The server is the single control plane that receives
            // node heartbeats, so its load balancer is the only one that can
            // route queries. Without this the GUI's own control plane sees zero
            // healthy nodes and queries fail with 503 no_healthy_nodes.
            { name: 'DELTA_FORGE_CONTROL_PLANE_URL', value: 'https://${appFqdn}/api/v1' }
            { name: 'AZURE_STORAGE_ACCOUNT_NAME', value: blobStorageName }
            { name: 'DELTA_FORGE_DEFAULT_STORAGE_ROOT', value: blobZoneRoot }
            { name: 'AZURE_KEY_VAULT_URL', value: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}' }
          ], empty(licenseKey) ? [] : [
            { name: 'DELTA_FORGE_LICENSE_KEY', secretRef: 'license-key' }
          ], smtpConfigured ? [
            { name: 'DELTA_FORGE_MAIL_PROVIDER', value: 'smtp' }
            { name: 'DELTA_FORGE_MAIL_FROM', value: empty(mailFrom) ? smtpUsername : mailFrom }
            { name: 'DELTA_FORGE_MAIL_FROM_NAME', value: mailFromName }
            { name: 'DELTA_FORGE_SMTP_HOST', value: smtpHost }
            { name: 'DELTA_FORGE_SMTP_PORT', value: string(smtpPort) }
            { name: 'DELTA_FORGE_SMTP_USERNAME', value: smtpUsername }
            { name: 'DELTA_FORGE_SMTP_STARTTLS', value: smtpStartTls ? 'true' : 'false' }
            { name: 'DELTA_FORGE_SMTP_PASSWORD', secretRef: 'smtp-password' }
          ] : [])
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  // Start after the platform has bootstrapped the catalog (seeded users/schema in
  // the shared Postgres), so the passive GUI never races the initial seed.
  dependsOn: [ app, pgDatabase, pgExtensions ]
}

// ============================ Slot pool (compute apps) ======================
// `slotCount` standalone compute Container Apps, idle at minReplicas=0 ($0 cold),
// each on its own external FQDN over managed TLS. The platform's autoscaler flips
// a slot 0->1 on demand via ARM (the Contributor grant below makes that possible).
resource slots 'Microsoft.App/containerApps@2026-01-01' = [for i in range(0, slotCount): if (deployClients) {
  name: slotNames[i]
  location: location
  tags: { 'deltaforge-tier': tier, 'deltaforge-role': 'compute-slot' }
  // Each slot gets its own system-assigned identity so a slot that serves a
  // query can read/write the storage account directly via managed identity
  // (granted Storage Blob Data Contributor below), the same passwordless path
  // the platform/embedded node uses.
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: ingressPort
        transport: 'auto'
        allowInsecure: false
        traffic: [ { latestRevision: true, weight: 100 } ]
      }
      registries: empty(registryServer) ? [] : [
        { server: registryServer, username: registryUsername, passwordSecretRef: 'acr-password' }
      ]
      secrets: concat(empty(registryServer) ? [] : [
        { name: 'acr-password', value: registryPassword }
      ], [
        // The slot presents the shared per-cluster NODE_SECRET as its node-join
        // credential: the SAME computeNodeSecret the platform sets as
        // DELTA_FORGE_NODE_SECRET, so register_node admits the slot via the
        // constant-time env_secret match. This is deliberately DECOUPLED from the
        // license: with subscription-attested auto-provisioning the license is
        // not known at deploy time (the platform mints it at boot), so it cannot
        // be the join credential. computeNodeSecret is a newGuid() generated once
        // per deployment and shared across the platform + every slot, so join
        // never depends on the license and never races a staged deploy.
        { name: 'node-secret', value: computeNodeSecret }
      ])
    }
    template: {
      containers: [
        {
          name: 'compute'
          image: computeImage
          resources: { cpu: json(slotCpuCores), memory: slotMemory }
          env: [
            { name: 'CONTROL_PLANE_URL', value: publicUrl }
            { name: 'NODE_ID', value: 'worker::${slotNames[i]}' }
            { name: 'NODE_SECRET', secretRef: 'node-secret' }
            { name: 'BIND_HOST', value: '0.0.0.0' }
            { name: 'BIND_PORT', value: string(ingressPort) }
            // The compute image creates its nonroot user with --no-create-home and
            // sets no HOME, so $HOME defaults to /home/nonroot, which does not
            // exist and uid 65532 cannot create. Anything the worker resolves under
            // the per-user data dir (most visibly the debug-trace file, via
            // dirs::data_local_dir) would then land on an unwritable path and be
            // silently discarded. Point HOME at /tmp (always writable in the
            // container) so the trace file and any other $HOME-rooted scratch are
            // actually written; the slot is stateless so ephemeral /tmp is fine.
            { name: 'HOME', value: '/tmp' }
            { name: 'DELTA_FORGE_COMPUTE_NODE_HOST', value: '${slotNames[i]}.${env.properties.defaultDomain}' }
            { name: 'DELTA_FORGE_COMPUTE_NODE_PORT', value: '443' }
            // Storage access for queries that route to this slot: same account
            // and default zone root as the platform, resolved via the slot's
            // own managed identity (no secrets).
            { name: 'AZURE_STORAGE_ACCOUNT_NAME', value: blobStorageName }
            { name: 'DELTA_FORGE_DEFAULT_STORAGE_ROOT', value: blobZoneRoot }
          ]
        }
      ]
      // Warm pool of one: slot 0 stays always-on (minReplicas 1) so the cluster
      // always has a ready compute node and the first query never pays a cold
      // start. Every other slot idles at zero ($0) and the autoscaler flips it
      // 0 -> 1 via ARM on demand. maxReplicas 1: one node per slot.
      scale: { minReplicas: (i == 0) ? 1 : 0, maxReplicas: 1 }
    }
  }
}]

// ====================== Managed-identity role grants ========================
resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(blobStorage.id, app.id, roleBlobContributor)
  scope: blobStorage
  properties: {
    principalId: app.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobContributor)
    principalType: 'ServicePrincipal'
  }
}
// Each slot's system-assigned identity gets Storage Blob Data Contributor on
// the storage account, so a slot serving a query reads/writes catalog tables
// over managed identity just like the platform does.
resource slotBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in range(0, slotCount): if (deployClients) {
  name: guid(blobStorage.id, slots[i].id, roleBlobContributor)
  scope: blobStorage
  properties: {
    principalId: slots[i].identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobContributor)
    principalType: 'ServicePrincipal'
  }
}]
// Each slot's identity also gets Key Vault Secrets Officer on the DATASOURCES
// vault. When a compute node creates a managed-identity backend store, the
// connection's sensitive material is written to (and later read from) this vault,
// so the slot needs read+write on it -- the same grant the platform and GUI
// identities already hold. NOT granted on the SYSTEM vault (platform secrets).
resource slotDsKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in range(0, slotCount): if (deployClients) {
  name: guid(dsKeyVault.id, slots[i].id, roleKvSecretsOfficer)
  scope: dsKeyVault
  properties: {
    principalId: slots[i].identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsOfficer)
    principalType: 'ServicePrincipal'
  }
}]
resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, app.id, roleKvSecretsOfficer)
  scope: keyVault
  properties: {
    principalId: app.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsOfficer)
    principalType: 'ServicePrincipal'
  }
}
// Platform MI also manages secrets in the Datasources vault (read + write), so
// connection credentials resolve over managed identity with no static secret.
resource dsKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dsKeyVault.id, app.id, roleKvSecretsOfficer)
  scope: dsKeyVault
  properties: {
    principalId: app.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsOfficer)
    principalType: 'ServicePrincipal'
  }
}
// Contributor on this resource group: lets the platform's system-assigned
// identity both (a) DISCOVER the pool by LISTING the Container Apps in this
// group (filtering on the `deltaforge-role=compute-slot` tag) and (b) flip each
// slot app's minReplicas (0 <-> 1) through the ARM REST API. Contributor
// includes Microsoft.App/containerApps read+write at this scope, so it covers
// the list query the autoscaler's discovery path makes as well as the PATCH.
// Scoped to the resource group, which contains the platform + every slot app.
// (Reader would suffice for discovery alone, but the flip needs write, so the
// single Contributor grant covers both rather than stacking two roles.)
resource contributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, app.id, roleContributor)
  scope: resourceGroup()
  properties: {
    principalId: app.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleContributor)
    principalType: 'ServicePrincipal'
  }
}
// GUI identity: read/write the storage account and BOTH Key Vaults over
// managed identity (same passwordless path as the platform), so catalog browsing
// and secret-backed datasource access work from the GUI. NO Contributor: the
// GUI never manages slots.
resource guiBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployClients) {
  name: guid(blobStorage.id, guiApp.id, roleBlobContributor)
  scope: blobStorage
  properties: {
    principalId: guiApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobContributor)
    principalType: 'ServicePrincipal'
  }
}
resource guiKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployClients) {
  name: guid(keyVault.id, guiApp.id, roleKvSecretsOfficer)
  scope: keyVault
  properties: {
    principalId: guiApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsOfficer)
    principalType: 'ServicePrincipal'
  }
}
resource guiDsKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployClients) {
  name: guid(dsKeyVault.id, guiApp.id, roleKvSecretsOfficer)
  scope: dsKeyVault
  properties: {
    principalId: guiApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsOfficer)
    principalType: 'ServicePrincipal'
  }
}

// =============================== Outputs ====================================
output tier string = tier
output slotCount int = slotCount
output guiEndpoint string = guiPublicUrl
output guiFqdn string = guiFqdn
output appFqdn string = appFqdn
output controlPlaneApiEndpoint string = 'https://${appFqdn}'
output postgresFqdn string = pgFqdn
output keyVaultName string = keyVaultName
output datasourcesKeyVaultName string = dsKeyVaultName
output blobZoneRoot string = blobZoneRoot
output slotApps array = slotNames
output slotFqdns array = [for i in range(0, slotCount): '${slotNames[i]}.${env.properties.defaultDomain}']
