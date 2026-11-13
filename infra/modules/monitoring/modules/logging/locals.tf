locals {
  docker_filter = "resource.type=\"gce_instance\" log_id(\"docker\")"
  container     = "REGEXP_EXTRACT(jsonPayload.attrs.tag, \"^iss-(.+)-[0-9]+$\")"

  log_filters = {
    iss_nginx_requests     = "${local.docker_filter} jsonPayload.attrs.tag=~\"-ui-\" jsonPayload.status:*"
    iss_nginx_request_time = "${local.docker_filter} jsonPayload.attrs.tag=~\"-ui-\" jsonPayload.status:*"
    iss_positions          = "${local.docker_filter} jsonPayload.log=~\"msg=.?position (published|stored)\""
    iss_container_errors   = "${local.docker_filter} jsonPayload.log=~\"level=ERROR| (ERROR|FATAL|PANIC):|[[](error|crit|alert|emerg)]\""
  }
}
