locals {
  members = {
    for name, acc in merge(var.readers, var.writers) :
    name => "serviceAccount:${acc.email}"
  }
  readers = { for name, acc in local.members : name => acc if contains(keys(var.readers), name) }
  writers = { for name, acc in local.members : name => acc if contains(keys(var.writers), name) }
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = local.readers

  project    = var.project_id
  location   = var.repository.location
  repository = local.repo_id
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writer" {
  for_each = local.writers

  project    = var.project_id
  location   = var.repository.location
  repository = local.repo_id
  role       = "roles/artifactregistry.writer"
  member     = each.value
}
