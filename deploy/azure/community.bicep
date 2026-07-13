// DeltaForge on Azure - Community tier ("Plan B" per-slot autoscaler pool).
//
// THIN per-tier wrapper. The whole implementation (platform + PostgreSQL + Blob
// + NFS storage + Key Vault + managed environment + managed identity + the slot
// loop + the autoscaler env + the Contributor role grant) lives in ONE place:
// modules/slot-pool.bicep. This wrapper only fixes the tier and the slot count,
// then passes every other parameter straight through. Single code path: the body
// is never copied per tier.
//
// slotCount = 1: the Community license node ceiling (2) minus the 1 always-on
// embedded compute node that runs inside the platform app. Bicep cannot read the
// license, so the ceiling is a per-template constant.

// ----------------------------- Pass-through params --------------------------
param location string = resourceGroup().location
@minLength(3)
@maxLength(16)
param namePrefix string = 'deltaforge'

param image string = 'ghcr.io/deltaforge-org/deltaforge-platform:latest'
param computeImage string = 'ghcr.io/deltaforge-org/deltaforge-compute:latest'
@secure()
param computeNodeSecret string = newGuid()

param registryServer string = ''
param registryUsername string = ''
@secure()
param registryPassword string = ''

param initImage string = 'mcr.microsoft.com/azurelinux/base/core:3.0'
param cpuCores string = '2.0'
param memory string = '4Gi'
param slotCpuCores string = '2.0'
param slotMemory string = '4Gi'

param adminEmail string = 'admin@deltaforge.local'
param engineerEmail string = 'engineer@deltaforge.local'
@secure()
param licenseKey string = ''
param consoleUrl string = 'https://console.deltaforge.org'
@secure()
param adminPassword string
@secure()
param engineerPassword string
@secure()
param pgAdminPassword string

param pgAdminUser string = 'dfadmin'
param pgSkuName string = 'Standard_B1ms'
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param pgTier string = 'Burstable'
param pgStorageGb int = 32
param pgVersion string = '16'

@minValue(100)
@maxValue(102400)
param dataShareGb int = 100

param smtpHost string = ''
param smtpPort int = 587
param smtpUsername string = ''
@secure()
param smtpPassword string = ''
param mailFrom string = ''
param mailFromName string = 'DeltaForge'
param smtpStartTls bool = true

param scalingCredentialRef string = ''

// ----------------------------- Tier constants -------------------------------
var tier = 'community'
var slotCount = 1 // Community ceiling (2 nodes) minus the 1 embedded platform node.

// ----------------------------- Single implementation ------------------------
module pool 'modules/slot-pool.bicep' = {
  name: 'df-slot-pool-${tier}'
  params: {
    tier: tier
    slotCount: slotCount
    location: location
    namePrefix: namePrefix
    image: image
    computeImage: computeImage
    computeNodeSecret: computeNodeSecret
    registryServer: registryServer
    registryUsername: registryUsername
    registryPassword: registryPassword
    initImage: initImage
    cpuCores: cpuCores
    memory: memory
    slotCpuCores: slotCpuCores
    slotMemory: slotMemory
    adminEmail: adminEmail
    engineerEmail: engineerEmail
    licenseKey: licenseKey
    consoleUrl: consoleUrl
    adminPassword: adminPassword
    engineerPassword: engineerPassword
    pgAdminPassword: pgAdminPassword
    pgAdminUser: pgAdminUser
    pgSkuName: pgSkuName
    pgTier: pgTier
    pgStorageGb: pgStorageGb
    pgVersion: pgVersion
    dataShareGb: dataShareGb
    smtpHost: smtpHost
    smtpPort: smtpPort
    smtpUsername: smtpUsername
    smtpPassword: smtpPassword
    mailFrom: mailFrom
    mailFromName: mailFromName
    smtpStartTls: smtpStartTls
    scalingCredentialRef: scalingCredentialRef
  }
}

// ----------------------------- Outputs (forwarded) --------------------------
output tier string = pool.outputs.tier
output slotCount int = pool.outputs.slotCount
output guiEndpoint string = pool.outputs.guiEndpoint
output appFqdn string = pool.outputs.appFqdn
output controlPlaneApiEndpoint string = pool.outputs.controlPlaneApiEndpoint
output postgresFqdn string = pool.outputs.postgresFqdn
output keyVaultName string = pool.outputs.keyVaultName
output datasourcesKeyVaultName string = pool.outputs.datasourcesKeyVaultName
output blobZoneRoot string = pool.outputs.blobZoneRoot
output slotApps array = pool.outputs.slotApps
output slotFqdns array = pool.outputs.slotFqdns
