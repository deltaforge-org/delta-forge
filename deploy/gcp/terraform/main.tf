# DeltaForge on GCP - single Platform node, fully self-contained.
#
# Provisions and bootstraps DeltaForge with no manual steps:
#   - Cloud SQL for PostgreSQL          -> the catalog (TLS enforced)
#   - Cloud Storage bucket              -> Delta/zone table data (object store)
#   - Secret Manager                    -> generated secrets
#   - Compute Engine VM (Ubuntu)        -> the Platform container (headless) +
#                                          a Caddy sidecar terminating HTTPS,
#                                          with a persistent disk for /data and a
#                                          service account that reads the bucket
#                                          (GCS via ADC) and the secrets
#   - Static external IP                -> stable address for DNS / certs
#
# This is the GCP analogue of deploy/azure/main.bicep; the container env contract
# is identical. The VM uses ambient credentials (the attached service account)
# for both GCS and Secret Manager, so no storage keys are stored anywhere.

locals {
  admin_password    = var.admin_password != "" ? var.admin_password : random_password.admin.result
  engineer_password = var.engineer_password != "" ? var.engineer_password : random_password.engineer.result

  # Endpoint advertised to clients and used by Caddy for its certificate.
  served_host = var.custom_domain != "" ? var.custom_domain : google_compute_address.this.address
  public_url  = var.enable_https ? "https://${local.served_host}" : "http://${google_compute_address.this.address}:3031"

  db_url = "postgres://dfadmin:${random_password.pg.result}@${google_sql_database_instance.this.public_ip_address}:5432/deltaforge?sslmode=require"

  smtp_configured = var.smtp_host != ""

  apis = [
    "compute.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each           = toset(local.apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ----------------------------- Generated secrets ---------------------------
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "-_.~"
}
resource "random_password" "engineer" {
  length           = 24
  special          = true
  override_special = "-_.~"
}
resource "random_password" "pg" {
  length           = 24
  special          = true
  override_special = "-_.~"
}

# ----------------------------- Networking ----------------------------------
resource "google_compute_network" "this" {
  name                    = "${var.name_prefix}-net"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.this]
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = "10.42.0.0/24"
  region        = var.region
  network       = google_compute_network.this.id
}

resource "google_compute_address" "this" {
  name       = "${var.name_prefix}-ip"
  region     = var.region
  depends_on = [google_project_service.this]
}

resource "google_compute_firewall" "web" {
  name      = "${var.name_prefix}-allow-web"
  network   = google_compute_network.this.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = var.enable_https ? ["80", "443"] : ["3000", "3031"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name_prefix}-platform"]
}

# SSH only via Identity-Aware Proxy (no public SSH surface).
resource "google_compute_firewall" "ssh_iap" {
  name      = "${var.name_prefix}-allow-ssh-iap"
  network   = google_compute_network.this.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-platform"]
}

# ----------------------------- PostgreSQL ----------------------------------
resource "google_sql_database_instance" "this" {
  name                = "${var.name_prefix}-pg"
  database_version    = var.db_version
  region              = var.region
  deletion_protection = false
  depends_on          = [google_project_service.this]

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_size         = var.db_disk_gb
    disk_type         = "PD_SSD"
    backup_configuration {
      enabled = true
    }
    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
      authorized_networks {
        name  = "platform-vm"
        value = google_compute_address.this.address
      }
    }
  }
}

resource "google_sql_database" "this" {
  name     = "deltaforge"
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "this" {
  name     = "dfadmin"
  instance = google_sql_database_instance.this.name
  password = random_password.pg.result
}

# ----------------------------- Storage -------------------------------------
# Delta/zone table data. The engine reaches it via the VM service account (ADC);
# the gs:// URL is an output the operator uses when creating a zone.
resource "google_storage_bucket" "tables" {
  name                        = "${var.name_prefix}-tables-${var.project_id}"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true
  depends_on                  = [google_project_service.this]
}

# ----------------------------- Service account -----------------------------
resource "google_service_account" "this" {
  account_id   = "${var.name_prefix}-platform"
  display_name = "DeltaForge Platform node"
  depends_on   = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "tables" {
  bucket = google_storage_bucket.tables.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.this.email}"
}

# ----------------------------- Secret Manager ------------------------------
resource "google_secret_manager_secret" "license" {
  secret_id = "${var.name_prefix}-license-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}
resource "google_secret_manager_secret_version" "license" {
  secret = google_secret_manager_secret.license.id
  # GCP secret versions cannot be empty, so store a sentinel when no license is
  # supplied; the startup script clears it to empty and the platform then
  # auto-provisions a Community license from its instance identity.
  secret_data = var.license_key != "" ? var.license_key : "auto-provision"
}

resource "google_secret_manager_secret" "admin_pw" {
  secret_id = "${var.name_prefix}-admin-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}
resource "google_secret_manager_secret_version" "admin_pw" {
  secret      = google_secret_manager_secret.admin_pw.id
  secret_data = local.admin_password
}

resource "google_secret_manager_secret" "engineer_pw" {
  secret_id = "${var.name_prefix}-engineer-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}
resource "google_secret_manager_secret_version" "engineer_pw" {
  secret      = google_secret_manager_secret.engineer_pw.id
  secret_data = local.engineer_password
}

resource "google_secret_manager_secret" "db_url" {
  secret_id = "${var.name_prefix}-db-url"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}
resource "google_secret_manager_secret_version" "db_url" {
  secret      = google_secret_manager_secret.db_url.id
  secret_data = local.db_url
}

resource "google_secret_manager_secret" "smtp_pw" {
  count     = local.smtp_configured ? 1 : 0
  secret_id = "${var.name_prefix}-smtp-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}
resource "google_secret_manager_secret_version" "smtp_pw" {
  count       = local.smtp_configured ? 1 : 0
  secret      = google_secret_manager_secret.smtp_pw[0].id
  secret_data = var.smtp_password
}

resource "google_secret_manager_secret" "registry" {
  count     = var.registry_credentials != null ? 1 : 0
  secret_id = "${var.name_prefix}-registry-credentials"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}
resource "google_secret_manager_secret_version" "registry" {
  count       = var.registry_credentials != null ? 1 : 0
  secret      = google_secret_manager_secret.registry[0].id
  secret_data = jsonencode(var.registry_credentials)
}

# Grant the VM service account read access to exactly the secrets it needs.
resource "google_secret_manager_secret_iam_member" "access" {
  for_each = merge(
    {
      license     = google_secret_manager_secret.license.id
      admin_pw    = google_secret_manager_secret.admin_pw.id
      engineer_pw = google_secret_manager_secret.engineer_pw.id
      db_url      = google_secret_manager_secret.db_url.id
    },
    local.smtp_configured ? { smtp_pw = google_secret_manager_secret.smtp_pw[0].id } : {},
    var.registry_credentials != null ? { registry = google_secret_manager_secret.registry[0].id } : {},
  )
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

# ----------------------------- Compute -------------------------------------
resource "google_compute_disk" "data" {
  name       = "${var.name_prefix}-data"
  type       = "pd-ssd"
  zone       = var.zone
  size       = var.data_disk_gb
  depends_on = [google_project_service.this]
}

resource "google_compute_instance" "this" {
  name         = "${var.name_prefix}-platform"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["${var.name_prefix}-platform"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 30
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "deltaforge-data"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {
      nat_ip = google_compute_address.this.address
    }
  }

  service_account {
    email  = google_service_account.this.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/startup-script.sh.tftpl", {
      project_id         = var.project_id
      image              = var.image
      caddy_image        = var.caddy_image
      enable_https       = var.enable_https
      caddy_domain       = local.served_host
      caddy_internal     = var.custom_domain == "" ? "--internal-certs" : ""
      admin_email        = var.admin_email
      engineer_email     = var.engineer_email
      public_url         = local.public_url
      tables_bucket_zone_root = "gs://${google_storage_bucket.tables.name}"
      tables_bucket_name = google_storage_bucket.tables.name
      console_url        = var.console_url
      license_secret     = google_secret_manager_secret.license.secret_id
      admin_pw_secret    = google_secret_manager_secret.admin_pw.secret_id
      engineer_pw_secret = google_secret_manager_secret.engineer_pw.secret_id
      db_url_secret      = google_secret_manager_secret.db_url.secret_id
      smtp_configured    = local.smtp_configured
      smtp_pw_secret     = local.smtp_configured ? google_secret_manager_secret.smtp_pw[0].secret_id : ""
      smtp_host          = var.smtp_host
      smtp_port          = var.smtp_port
      smtp_username      = var.smtp_username
      mail_from          = var.mail_from != "" ? var.mail_from : var.smtp_username
      mail_from_name     = var.mail_from_name
      smtp_starttls      = var.smtp_starttls
      registry_secret    = var.registry_credentials != null ? google_secret_manager_secret.registry[0].secret_id : ""
    })
  }

  depends_on = [
    google_secret_manager_secret_version.license,
    google_secret_manager_secret_version.admin_pw,
    google_secret_manager_secret_version.engineer_pw,
    google_secret_manager_secret_version.db_url,
    google_secret_manager_secret_iam_member.access,
    google_storage_bucket_iam_member.tables,
    google_sql_user.this,
    google_sql_database.this,
  ]
}
