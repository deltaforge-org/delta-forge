output "console_url" {
  description = "DeltaForge web console / API URL."
  value       = local.public_url
}

output "instance_ip" {
  description = "Stable static external IP (point a custom-domain A record here)."
  value       = google_compute_address.this.address
}

output "postgres_host" {
  description = "Cloud SQL public IP (catalog)."
  value       = google_sql_database_instance.this.public_ip_address
}

output "tables_bucket_zone_root" {
  description = "GCS zone root to use when creating Delta/zone storage."
  value       = "gs://${google_storage_bucket.tables.name}"
}

output "admin_email" {
  description = "Seeded admin login."
  value       = var.admin_email
}

output "admin_password" {
  description = "Admin password (also stored in Secret Manager)."
  value       = local.admin_password
  sensitive   = true
}

output "engineer_password" {
  description = "Engineer password (also stored in Secret Manager)."
  value       = local.engineer_password
  sensitive   = true
}

output "secret_names" {
  description = "Secret Manager secret IDs holding the generated credentials."
  value = {
    license     = google_secret_manager_secret.license.secret_id
    admin_pw    = google_secret_manager_secret.admin_pw.secret_id
    engineer_pw = google_secret_manager_secret.engineer_pw.secret_id
    db_url      = google_secret_manager_secret.db_url.secret_id
  }
}
