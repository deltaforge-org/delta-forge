# DeltaForge on GCP - input variables. This file IS the deployment interface
# (the GCP analogue of deploy/azure/main.bicep parameters).

variable "project_id" {
  type        = string
  description = "GCP project ID to deploy into."
}

variable "region" {
  type        = string
  default     = "europe-west1"
  description = "GCP region."
}

variable "zone" {
  type        = string
  default     = "europe-west1-b"
  description = "GCP zone for the VM and its persistent disk."
}

variable "name_prefix" {
  type        = string
  default     = "deltaforge"
  description = "Short prefix for resource names (lowercase letters, digits, hyphens)."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}$", var.name_prefix))
    error_message = "name_prefix must be 2-19 chars: lowercase letter first, then letters/digits/hyphens."
  }
}

variable "image" {
  type        = string
  default     = "ghcr.io/deltaforge-org/platform:latest"
  description = "DeltaForge Platform container image (Artifact Registry, ghcr.io, or any registry)."
}

variable "registry_credentials" {
  type = object({
    server   = string
    username = string
    password = string
  })
  default     = null
  sensitive   = true
  description = "Optional Docker registry login for a private image. null for public images / Artifact Registry reachable by the VM service account."
}

variable "license_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "DeltaForge license key. Leave empty to auto-provision a Community license on first boot: the VM presents its Google-signed instance identity to the DeltaForge console (project-attested), so no pre-obtained key is needed. Set a key only to pin a purchased/higher tier."
}

variable "console_url" {
  type        = string
  default     = "https://console.deltaforge.org"
  description = "DeltaForge console (license service) base URL used for project-attested auto-provisioning when license_key is empty."
}

variable "admin_email" {
  type        = string
  default     = "admin@deltaforge.local"
  description = "Seeded admin account email."
}

variable "engineer_email" {
  type        = string
  default     = "engineer@deltaforge.local"
  description = "Seeded engineer account email."
}

variable "admin_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Admin password. Empty to auto-generate (stored in Secret Manager)."
}

variable "engineer_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Engineer password. Empty to auto-generate (stored in Secret Manager)."
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-4"
  description = "Compute Engine machine type for the Platform VM (4 vCPU / 16 GB default)."
}

variable "data_disk_gb" {
  type        = number
  default     = 100
  description = "Persistent disk size (GiB) for /data (config + git workspace clones + engine state)."
}

variable "db_tier" {
  type        = string
  default     = "db-custom-1-3840"
  description = "Cloud SQL machine tier (1 vCPU / 3.75 GB default)."
}

variable "db_disk_gb" {
  type        = number
  default     = 32
  description = "Cloud SQL storage (GiB)."
}

variable "db_version" {
  type        = string
  default     = "POSTGRES_16"
  description = "Cloud SQL PostgreSQL version."
}

variable "enable_https" {
  type        = bool
  default     = true
  description = "Front the console/API with a Caddy sidecar terminating HTTPS. true for cloud; false exposes plain HTTP (console 3031, control plane 3000)."
}

variable "custom_domain" {
  type        = string
  default     = ""
  description = "Custom domain for a trusted Let's Encrypt certificate. Point its DNS A record at the static IP after first apply. Empty = use the static IP with Caddy's internal cert (browser warning; curl -k)."
}

variable "caddy_image" {
  type        = string
  default     = "caddy:2.8-alpine"
  description = "Caddy image for the TLS sidecar."
}

# ---- Optional SMTP mailer (mirrors the Bicep smtp* params) ----
variable "smtp_host" {
  type        = string
  default     = ""
  description = "SMTP server host. Empty skips mailer configuration (mail is logged)."
}
variable "smtp_port" {
  type        = number
  default     = 587
  description = "SMTP port."
}
variable "smtp_username" {
  type        = string
  default     = ""
  description = "SMTP username."
}
variable "smtp_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "SMTP password."
}
variable "mail_from" {
  type        = string
  default     = ""
  description = "From address for outbound mail (defaults to smtp_username if empty)."
}
variable "mail_from_name" {
  type        = string
  default     = "DeltaForge"
  description = "From display name for outbound mail."
}
variable "smtp_starttls" {
  type        = bool
  default     = true
  description = "Use STARTTLS for SMTP."
}
