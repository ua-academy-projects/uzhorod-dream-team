# VMs consume these emails, so the service accounts get their roles before any VM starts as them
output "vm_emails" {
  value = { for k, sa in google_service_account.vm : k => sa.email }

  depends_on = [
    google_project_iam_member.vm_base,
    google_project_iam_member.cloudsql_client,
    google_storage_bucket_iam_member.artifact_reader,
  ]
}

# output "ansible_email" {
#   value = google_service_account.ansible.email
# }

output "artifacts_bucket" {
  value = google_storage_bucket.artifacts.name
}
