moved {
  from = module.cloudsql
  to   = module.cloudsql[0]
}

moved {
  from = module.network.google_compute_global_address.psa
  to   = module.network.google_compute_global_address.psa[0]
}

moved {
  from = module.network.google_service_networking_connection.psa
  to   = module.network.google_service_networking_connection.psa[0]
}

moved {
  from = module.iam.google_project_iam_member.cloudsql
  to   = module.iam.google_project_iam_member.grant
}
