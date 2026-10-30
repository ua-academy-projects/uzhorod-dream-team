resource "google_service_account" "vm" {
  for_each = {
    for name, cfg in local.cfg.vm :
    name => cfg if lookup(cfg, "needs_registry", false) || length(toset(lookup(cfg, "secrets", []))) > 0
  }

  account_id   = "kyiv-air-${each.key}"
  display_name = "Kyiv Air ${title(each.key)}"
}
