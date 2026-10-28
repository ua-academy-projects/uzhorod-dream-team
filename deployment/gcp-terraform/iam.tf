resource "google_service_account" "vm" {
  for_each = {
    for name, cfg in local.cfg.vm :
    name => cfg if cfg.needs_registry || length(cfg.secrets) > 0
  }

  account_id   = "kyiv-air-${each.key}"
  display_name = "Kyiv Air ${title(each.key)}"
}
