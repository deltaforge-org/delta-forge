// DeltaForge on Azure — single Platform node, fully self-contained.
//
// This template IS the deployment interface: every knob a buyer needs is a
// parameter here. It provisions, wires, and bootstraps DeltaForge with no manual
// steps:
//   - Azure Database for PostgreSQL Flexible Server   -> the catalog (TLS on)
//   - Azure Storage: a file share (/data: config + git workspace clones) and a
//     blob container (Delta/zone table data, the durable "scratch" the engine
//     writes to in cloud, since container/SMB filesystems can't do Delta commits)
//   - Azure Key Vault                                 -> generated secrets
//   - Azure Container Instance (the Platform binary, headless) with a
//     system-assigned managed identity that reads Blob + Key Vault
//   - Optional Caddy sidecar terminating HTTPS in front of the web console
//
// The Platform serves its web console (the canonical config UI) on the same
// origin as the API; SQL via CLI/VS Code/ODBC/ADBC is the secondary path.
// Secrets are generated here and stored in Key Vault; non-secret settings are
// plain parameters. Auto-bootstrap from these values means no interactive setup.

// ─────────────────────────────── Core ───────────────────────────────────────
@description('Location for all resources.')
param location string = resourceGroup().location

@description('Short prefix for resource names. Lowercase letters and digits.')
@minLength(3)
@maxLength(16)
param namePrefix string = 'deltaforge'

@description('DeltaForge Platform container image.')
param image string = 'ghcr.io/deltaforge-org/platform:latest'

@description('Registry login server for a private image (e.g. ghcr.io or <acr>.azurecr.io). Empty for a public image.')
param registryServer string = ''
@description('Registry username (private image).')
param registryUsername string = ''
@description('Registry password / token (private image).')
@secure()
param registryPassword string = ''

@description('vCPU for the Platform container.')
param cpuCores int = 3
@description('Memory (GiB) for the Platform container.')
param memoryGb int = 8

// ─────────────────────────── Seeded accounts ────────────────────────────────
@description('Seeded admin account email.')
param adminEmail string = 'admin@deltaforge.local'
@description('Seeded engineer account email.')
param engineerEmail string = 'engineer@deltaforge.local'
@description('DeltaForge license key.')
@secure()
param licenseKey string

// Secrets are generated (random GUIDs satisfy the >=12-char + symbol policy via
// their hyphens) unless explicitly supplied. They are stored in Key Vault.
@description('Admin password. Leave default to auto-generate.')
@secure()
param adminPassword string = newGuid()
@description('Engineer password. Leave default to auto-generate.')
@secure()
param engineerPassword string = newGuid()
@description('PostgreSQL administrator password. Leave default to auto-generate.')
@secure()
param pgAdminPassword string = newGuid()

// ───────────────────────────── PostgreSQL ───────────────────────────────────
@description('PostgreSQL administrator login.')
param pgAdminUser string = 'dfadmin'
@description('PostgreSQL compute SKU.')
param pgSkuName string = 'Standard_B1ms'
@description('PostgreSQL compute tier.')
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param pgTier string = 'Burstable'
@description('PostgreSQL storage (GiB).')
param pgStorageGb int = 32
@description('PostgreSQL major version.')
param pgVersion string = '16'

// ───────────────────────────── Storage ──────────────────────────────────────
@description('File share size (GiB) for /data (config + git workspace clones).')
param dataShareGb int = 100

// ───────────────────────────── Mailer (SMTP) ────────────────────────────────
// Optional. When smtpHost is set, the Platform sends mail via SMTP; otherwise it
// logs mail (no external mailer). All adjustable post-deploy from the console.
@description('SMTP server host. Leave empty to skip mailer configuration.')
param smtpHost string = ''
@description('SMTP port.')
param smtpPort int = 587
@description('SMTP username.')
param smtpUsername string = ''
@description('SMTP password.')
@secure()
param smtpPassword string = ''
@description('From address for outbound mail.')
param mailFrom string = ''
@description('From display name for outbound mail.')
param mailFromName string = 'DeltaForge'
@description('Use STARTTLS for SMTP.')
param smtpStartTls bool = true

// ───────────────────────────── HTTPS front ──────────────────────────────────
@description('Front the console/API with a Caddy sidecar that terminates HTTPS. Keep true for cloud; false for plain HTTP only.')
param enableHttps bool = true
@description('Custom domain for a trusted Let\'s Encrypt certificate. Point its DNS at the container IP after first deploy. Empty = the *.azurecontainer.io FQDN (Caddy internal cert; browser warning).')
param customDomain string = ''
@description('Caddy image for the TLS sidecar.')
param caddyImage string = 'caddy:2.8-alpine'

@description('Escape hatch for pre-TLS images only: disable Postgres SSL enforcement and connect with sslmode=disable.')
param disableDbSsl bool = false

// ─────────────────────────── Derived names ──────────────────────────────────
var suffix = uniqueString(resourceGroup().id)
var pgServerName = toLower('${namePrefix}-pg-${suffix}')
var storageName = toLower(take(replace('${namePrefix}${suffix}', '-', ''), 24))
var keyVaultName = toLower(take('${namePrefix}kv${suffix}', 24))
var shareName = 'data'
var caddyShareName = 'caddy'
var blobContainerName = 'deltatables'
var databaseName = 'deltaforge'
var dnsLabel = toLower('${namePrefix}-${suffix}')
var containerName = '${namePrefix}-platform'
var pgFqdn = '${pgServerName}.postgres.database.azure.com'
var fqdn = '${dnsLabel}.${location}.azurecontainer.io'
var caddyDomain = empty(customDomain) ? fqdn : customDomain
var sslMode = disableDbSsl ? 'disable' : 'require'
var dbUrl = 'postgres://${pgAdminUser}:${pgAdminPassword}@${pgFqdn}:5432/${databaseName}?sslmode=${sslMode}'
var blobZoneRoot = 'abfss://${blobContainerName}@${storageName}.dfs.${environment().suffixes.storage}'
var publicUrl = enableHttps ? 'https://${caddyDomain}' : 'http://${fqdn}:3031'
var usePrivateRegistry = !empty(registryServer)
var smtpConfigured = !empty(smtpHost)
// Built-in role IDs.
var roleBlobContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
var roleKvSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'  // Key Vault Secrets User
// Public ports: HTTPS (+ ACME) when fronted by Caddy; else console (3031) + control plane (3000).
var groupPorts = enableHttps ? [
  { protocol: 'TCP', port: 443 }
  { protocol: 'TCP', port: 80 }
] : [
  { protocol: 'TCP', port: 3031 }
  { protocol: 'TCP', port: 3000 }
]

// ───────────────────────────── PostgreSQL ───────────────────────────────────
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

resource pgFirewallAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: pg
  name: 'AllowAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource pgDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: pg
  name: databaseName
  properties: { charset: 'UTF8', collation: 'en_US.utf8' }
}

// btree_gist is created by the first bootstrap migration; Azure blocks unlisted
// extensions, so allow-list it here. Dynamic parameter (no restart).
resource pgExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: pg
  name: 'azure.extensions'
  properties: { value: 'btree_gist', source: 'user-override' }
}

resource pgSslParam 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = if (disableDbSsl) {
  parent: pg
  name: 'require_secure_transport'
  properties: { value: 'off', source: 'user-override' }
}

// ───────────────────────────── Storage ──────────────────────────────────────
resource storage 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: { minimumTlsVersion: 'TLS1_2', allowBlobPublicAccess: false }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2026-04-01' = {
  parent: storage
  name: 'default'
}
resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2026-04-01' = {
  parent: fileService
  name: shareName
  properties: { shareQuota: dataShareGb }
}
resource caddyShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2026-04-01' = if (enableHttps) {
  parent: fileService
  name: caddyShareName
  properties: { shareQuota: 1 }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2026-04-01' = {
  parent: storage
  name: 'default'
}
// Delta/zone table data. Container/SMB filesystems can't do Delta's atomic
// commit; Blob (object store) can, and it's durable across restarts.
resource tablesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-04-01' = {
  parent: blobService
  name: blobContainerName
  properties: { publicAccess: 'None' }
}

// ───────────────────────────── Key Vault ────────────────────────────────────
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

resource kvPgPassword 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: keyVault
  name: 'postgres-admin-password'
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
resource kvSmtpPassword 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = if (smtpConfigured) {
  parent: keyVault
  name: 'smtp-password'
  properties: { value: smtpPassword }
}

// ───────────────────────── Container instance ───────────────────────────────
resource aci 'Microsoft.ContainerInstance/containerGroups@2025-09-01' = {
  name: containerName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    osType: 'Linux'
    restartPolicy: 'OnFailure'
    imageRegistryCredentials: usePrivateRegistry ? [
      { server: registryServer, username: registryUsername, password: registryPassword }
    ] : []
    ipAddress: {
      type: 'Public'
      dnsNameLabel: dnsLabel
      ports: groupPorts
    }
    volumes: concat([
      {
        name: 'data'
        azureFile: {
          shareName: shareName
          storageAccountName: storage.name
          storageAccountKey: storage.listKeys().keys[0].value
        }
      }
    ], enableHttps ? [
      {
        name: 'caddy'
        azureFile: {
          shareName: caddyShareName
          storageAccountName: storage.name
          storageAccountKey: storage.listKeys().keys[0].value
        }
      }
    ] : [])
    containers: concat([
      {
        name: containerName
        properties: {
          image: image
          resources: { requests: { cpu: cpuCores, memoryInGB: memoryGb } }
          ports: [
            { protocol: 'TCP', port: 3000 }
            { protocol: 'TCP', port: 3031 }
          ]
          volumeMounts: [ { name: 'data', mountPath: '/data' } ]
          environmentVariables: concat([
            { name: 'DELTA_FORGE_DB_URL', secureValue: dbUrl }
            { name: 'DELTA_FORGE_ADMIN_EMAIL', value: adminEmail }
            { name: 'DELTA_FORGE_ENGINEER_EMAIL', value: engineerEmail }
            { name: 'DELTA_FORGE_ACTIVATE_ON_BOOT', value: '1' }
            // Single-container variant: the platform no longer embeds a compute
            // node, so spawn + auto-approve a co-located delta-forge-compute child
            // (bundled side-by-side in the image). The slot-pool template instead
            // runs compute as a separate, autoscaled container and leaves this off.
            { name: 'DELTA_FORGE_COMPUTE_AUTOSPAWN', value: '1' }
            { name: 'DELTA_FORGE_PUBLIC_URL', value: publicUrl }
            { name: 'AZURE_STORAGE_ACCOUNT_NAME', value: storageName }
            { name: 'DELTA_FORGE_ADMIN_PASSWORD', secureValue: adminPassword }
            { name: 'DELTA_FORGE_ENGINEER_PASSWORD', secureValue: engineerPassword }
            { name: 'DELTA_FORGE_LICENSE_KEY', secureValue: licenseKey }
          ], smtpConfigured ? [
            { name: 'DELTA_FORGE_MAIL_PROVIDER', value: 'smtp' }
            { name: 'DELTA_FORGE_MAIL_FROM', value: empty(mailFrom) ? smtpUsername : mailFrom }
            { name: 'DELTA_FORGE_MAIL_FROM_NAME', value: mailFromName }
            { name: 'DELTA_FORGE_SMTP_HOST', value: smtpHost }
            { name: 'DELTA_FORGE_SMTP_PORT', value: string(smtpPort) }
            { name: 'DELTA_FORGE_SMTP_USERNAME', value: smtpUsername }
            { name: 'DELTA_FORGE_SMTP_STARTTLS', value: smtpStartTls ? 'true' : 'false' }
            { name: 'DELTA_FORGE_SMTP_PASSWORD', secureValue: smtpPassword }
          ] : [])
        }
      }
    ], enableHttps ? [
      {
        name: 'caddy'
        properties: {
          image: caddyImage
          // Real HTTPS for the console. Custom domain -> trusted Let's Encrypt;
          // bare *.azurecontainer.io -> Caddy internal cert (avoids LE rate limits
          // on the shared domain). Proxies to the console on localhost:3031.
          command: concat([
            'caddy', 'reverse-proxy', '--from', caddyDomain, '--to', 'localhost:3031'
          ], empty(customDomain) ? [ '--internal-certs' ] : [])
          resources: { requests: { cpu: 1, memoryInGB: 1 } }
          ports: [
            { protocol: 'TCP', port: 443 }
            { protocol: 'TCP', port: 80 }
          ]
          volumeMounts: [ { name: 'caddy', mountPath: '/data' } ]
        }
      }
    ] : [])
  }
  dependsOn: enableHttps ? [
    pgFirewallAzure, pgDatabase, pgExtensions, share, caddyShare, tablesContainer
  ] : [
    pgFirewallAzure, pgDatabase, pgExtensions, share, tablesContainer
  ]
}

// ───────────────────── Managed-identity role grants ─────────────────────────
// The Platform's identity reads Delta data from Blob and secrets from Key Vault.
resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, aci.id, roleBlobContributor)
  scope: storage
  properties: {
    principalId: aci.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobContributor)
    principalType: 'ServicePrincipal'
  }
}
resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, aci.id, roleKvSecretsUser)
  scope: keyVault
  properties: {
    principalId: aci.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKvSecretsUser)
    principalType: 'ServicePrincipal'
  }
}

// ───────────────────────────── Outputs ──────────────────────────────────────
output consoleUrl string = publicUrl
output postgresFqdn string = pgFqdn
output keyVaultName string = keyVaultName
output blobZoneRoot string = blobZoneRoot
output httpsEnabled bool = enableHttps
output servedDomain string = caddyDomain
