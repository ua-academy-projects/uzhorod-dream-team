# Images are built once by ../build.sh and pulled by the VMs.

resource "google_artifact_registry_repository" "crypto" {
  repository_id = "crypto"
  location      = var.region
  format        = "DOCKER"
  description   = "crypto-price-service images, tagged with the git commit."

  # A tag always means the same image: a rollback is the previous tag.
  docker_config {
    immutable_tags = true
  }

  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }

  depends_on = [google_project_service.this]
}

# The build runs as its own account: it may push images and write its log, nothing else.
resource "google_service_account" "build" {
  account_id   = "crypto-build"
  display_name = "crypto-price-service Cloud Build"

  depends_on = [google_project_service.this]
}

resource "google_artifact_registry_repository_iam_member" "build_writer" {
  repository = google_artifact_registry_repository.crypto.name
  location   = google_artifact_registry_repository.crypto.location
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# gcloud uploads the source here; the build reads it.
# Uploads expire after 7 days: versioning and access logs would only keep noise.
#trivy:ignore:GCP-0078
#trivy:ignore:GCP-0077
resource "google_storage_bucket" "build_source" {
  name                        = "${var.project_id}-build-source"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "build_source_reader" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.build.email}"
}

# The service VMs only pull.
resource "google_artifact_registry_repository_iam_member" "vm_reader" {
  for_each = local.services

  repository = google_artifact_registry_repository.crypto.name
  location   = google_artifact_registry_repository.crypto.location
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.vm[each.key].email}"
}
