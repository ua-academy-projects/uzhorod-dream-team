from __future__ import annotations

DOCUMENTATION = r"""
name: gcp_vms
author: Oleksiy Lohoyda (@oleksiy-lohoyda)
short_description: Weather Forecast VMs from Google Cloud
description:
  - Adds every running VM named C({prefix}-{vm}) where C(vm) is in C(vms.instances) of the config.
  - Groups hosts by VM role, C(bastion) or C(node). Nodes are reached through the bastion.
  - Sets C(cloudsql_private_ip) when the Cloud SQL instance C({prefix}-db) exists.
  - Uses GOOGLE_APPLICATION_CREDENTIALS.
options:
  plugin:
    description: Name of this plugin.
    required: true
    choices: [oleksiy_lohoyda.weather.gcp_vms]
  project:
    description: Google Cloud project ID.
    required: true
    env:
      - name: PROJECT_ID
  config_path:
    description: Deployment config.
    type: path
    default: ~/.config/weather-forecast/deployment.json
    env:
      - name: WEATHER_CONFIG
  ssh_key:
    description: Private SSH key.
    type: path
    default: ~/.ssh/weather_vm
    env:
      - name: WEATHER_SSH_KEY
requirements:
  - google-auth
"""

import json

import google.auth
from google.auth.transport.requests import AuthorizedSession
from ansible.plugins.inventory import BaseInventoryPlugin


class InventoryModule(BaseInventoryPlugin):
    NAME = "oleksiy_lohoyda.weather.gcp_vms"

    def parse(self, inventory, loader, path, cache=True):
        super().parse(inventory, loader, path, cache)
        self._read_config_data(path)
        project = self.get_option("project")
        key = self.get_option("ssh_key")
        with open(self.get_option("config_path")) as file:
            config = json.load(file)
        prefix = config["project"]["prefix"]

        credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        http = AuthorizedSession(credentials)
        pages = http.get(
            f"https://compute.googleapis.com/compute/v1/projects/{project}/aggregated/instances",
            params={"filter": 'status = "RUNNING"', "maxResults": 500},
        )
        pages.raise_for_status()
        running = {
            instance["name"]: instance["networkInterfaces"][0]
            for zone in pages.json().get("items", {}).values()
            for instance in zone.get("instances", [])
        }

        ssh = config["ssh"]
        options = "-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30"
        bastion_ip = None
        for name, vm in config["vms"]["instances"].items():
            if vm.get("role") == "bastion" and f"{prefix}-{name}" in running:
                bastion_ip = running[f"{prefix}-{name}"]["accessConfigs"][0]["natIP"]

        self.inventory.add_group("node")
        for name, vm in config["vms"]["instances"].items():
            interface = running.get(f"{prefix}-{name}")
            if interface is None or vm.get("role") == "bastion":
                continue
            self.inventory.add_host(name, group="node")
            self.inventory.set_variable(name, "ansible_host", interface["networkIP"])
            self.inventory.set_variable(name, "ansible_port", ssh["port"])
            self.inventory.set_variable(name, "ansible_ssh_private_key_file", key)
            self.inventory.set_variable(
                name,
                "ansible_ssh_common_args",
                f"{options} -o ProxyCommand='ssh -i {key} {options} -p {ssh['port']} -W %h:%p {ssh['jump_user']}@{bastion_ip}'",
            )

        cloudsql = http.get(f"https://sqladmin.googleapis.com/v1/projects/{project}/instances/{prefix}-db")
        addresses = cloudsql.json().get("ipAddresses", []) if cloudsql.ok else []
        self.inventory.set_variable(
            "all", "cloudsql_private_ip", next((a["ipAddress"] for a in addresses if a["type"] == "PRIVATE"), None)
        )
