# Google Cloud Ops Agent (logs + metrics) on every Ubuntu VM, installed and kept in place by VM Manager.
#
# How it works: the OS Config agent that ships in the Ubuntu GCE images reads the OS policy assignment below
# (it needs the instance metadata enable-osconfig=TRUE, set in modules/instances) and runs the exec resource as root.
# The VM service accounts already carry roles/logging.logWriter and roles/monitoring.metricWriter (modules/iam).
# An assignment is zonal and its instance filter selects by zone, so one per zone, each matching all VMs of that zone.
resource "google_os_config_os_policy_assignment" "ops_agent" {
  for_each    = var.zones
  project     = var.project_id
  location    = each.key
  name        = "ops-agent"
  description = "Install the Google Cloud Ops Agent"

  # do not make terraform apply wait until every VM has finished the rollout
  skip_await_rollout = true

  instance_filter {
    all = true
  }

  os_policies {
    id   = "ops-agent"
    mode = "ENFORCEMENT"

    resource_groups {
      inventory_filters {
        os_short_name = "ubuntu"
      }

      resources {
        id = "install-ops-agent"

        exec {
          # exit 100 = already as desired, 101 = needs enforcing
          validate {
            interpreter = "SHELL"
            script      = <<-EOT
              dpkg-query -W -f='$${Status}' google-cloud-ops-agent 2>/dev/null | grep -q 'install ok installed' && exit 100
              exit 101
            EOT
          }

          # the official repo script adds the apt repository and installs the package (which enables and starts the service);
          # exit 100 = enforced
          enforce {
            interpreter = "SHELL"
            script      = <<-EOT
              set -eu
              curl -fsS -o /tmp/add-google-cloud-ops-agent-repo.sh https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
              bash /tmp/add-google-cloud-ops-agent-repo.sh --also-install
              rm -f /tmp/add-google-cloud-ops-agent-repo.sh
              exit 100
            EOT
          }
        }
      }
    }
  }

  rollout {
    disruption_budget {
      percent = 100
    }
    min_wait_duration = "0s"
  }
}

# --- nginx logs --------------------------------------------------------------------------------------------------
# By default the agent does not read nginx. This policy writes the agent config on the VMs labelled ops_agent=nginx
# (the frontend), so access.log is parsed (httpRequest.status etc.) and reaches Cloud Logging as log "nginx_access".
# The alerts built on top of it are in alerts.tf. The agent merges this file with its built-in defaults.
locals {
  nginx_agent_config = trimspace(yamlencode({
    logging = {
      receivers = {
        nginx_access = { type = "nginx_access" }
      }
      service = {
        pipelines = {
          nginx = { receivers = ["nginx_access"] }
        }
      }
    }
  }))
  # the heredoc in "enforce" adds exactly one newline after the config; the hash must be of the file as written
  nginx_agent_config_sha = sha256("${local.nginx_agent_config}\n")
}

resource "google_os_config_os_policy_assignment" "nginx" {
  for_each    = var.nginx_zones
  project     = var.project_id
  location    = each.key
  name        = "ops-agent-nginx"
  description = "Ops Agent: read the nginx access log"

  skip_await_rollout = true

  instance_filter {
    inclusion_labels {
      labels = {
        ops_agent = "nginx"
      }
    }
  }

  os_policies {
    id   = "ops-agent-nginx"
    mode = "ENFORCEMENT"

    resource_groups {
      inventory_filters {
        os_short_name = "ubuntu"
      }

      # One exec resource on purpose: if the file were a separate resource it could be written before the package is
      # installed (the policy "ops-agent" installs it independently), which makes dpkg treat it as a conffile conflict.
      resources {
        id = "nginx-agent-config"

        exec {
          # 100 = package installed and the config is the expected one
          validate {
            interpreter = "SHELL"
            script      = <<EOT
dpkg-query -W -f='$${Status}' google-cloud-ops-agent 2>/dev/null | grep -q 'install ok installed' || exit 101
[ "$(sha256sum /etc/google-cloud-ops-agent/config.yaml 2>/dev/null | cut -d' ' -f1)" = "${local.nginx_agent_config_sha}" ] && exit 100
exit 101
EOT
          }

          # package not there yet = fail (retried at the next cycle, after the "ops-agent" policy installed it)
          enforce {
            interpreter = "SHELL"
            script      = <<EOT
set -eu
dpkg-query -W -f='$${Status}' google-cloud-ops-agent 2>/dev/null | grep -q 'install ok installed' || { echo "ops agent is not installed yet" >&2; exit 1; }
cat > /etc/google-cloud-ops-agent/config.yaml <<'CONF'
${local.nginx_agent_config}
CONF
systemctl restart google-cloud-ops-agent
exit 100
EOT
          }
        }
      }
    }
  }

  rollout {
    disruption_budget {
      percent = 100
    }
    min_wait_duration = "0s"
  }

  depends_on = [google_os_config_os_policy_assignment.ops_agent]
}
