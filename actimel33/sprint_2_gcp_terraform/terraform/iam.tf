# These get nothing but their own secrets.
resource "google_service_account" "vm" {
  for_each = local.machines

  account_id   = "crypto-${each.key}"
  display_name = "crypto-price-service ${each.key} VM"

  depends_on = [google_project_service.this]
}
