# The service accounts of the VMs moved from the vms module to the service_accounts module.
moved {
  from = module.vms.google_service_account.vm
  to   = module.service_accounts.google_service_account.vm
}
