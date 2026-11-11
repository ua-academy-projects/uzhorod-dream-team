# -*- coding: utf-8 -*-
"""Inventory plugin: the VMs of CityBikes. A wrapper around google.cloud.gcp_compute, set up from config.json."""

DOCUMENTATION = r"""
name: gcp
short_description: The VMs of CityBikes (google.cloud.gcp_compute, set up from config.json)
description:
  - A wrapper around C(google.cloud.gcp_compute). The inventory file names only this plugin; the plugin sets
    gcp_compute up by itself (the project and the key of the service account, only the VMs with the label
    C(vm)) and lets it list the VMs.
  - Its settings with vms.defaults filled in go to C(citybikes_vm), and how to reach it to the connection
    variables. The keys come from your ssh-agent (only the public key files are named), the bastion directly
    on ssh.bastion_port, every other VM through the bastion (ssh -W, the bastion holds no key).
  - For every host and for localhost it sets C(citybikes_config_file), the path of config.json. The role
    config_validate loads it with include_vars.
  - And C(citybikes_db_host), the address of the database. The private IP of the Cloud SQL instance
    C(<prefix>-pg), from the Cloud SQL Admin API. Empty while the instance does not exist.
  - The name of the inventory file must end with C(citybikes.yml).
options:
  plugin:
    description: Marks the file as ours.
    required: true
    choices: [citybikes.infra.gcp]
  config:
    description: Path of config.json. Default C(../../infra/config.json) from the inventory file.
    type: path
    env:
      - name: CITYBIKES_CONFIG
  credentials_file:
    description: Key file of the service account (infra/bootstrap/terraform.env sets it). The project is the one of the key.
    type: path
    required: true
    env:
      - name: GOOGLE_APPLICATION_CREDENTIALS
requirements: [google-auth, requests]
"""

EXAMPLES = r"""
# ansible/inventory/citybikes.yml
plugin: citybikes.infra.gcp
"""

import json
import os
import tempfile

from ansible.errors import AnsibleParserError
from ansible.plugins.inventory import BaseInventoryPlugin
from ansible.plugins.loader import inventory_loader
from ansible.utils.display import Display

display = Display()


def gcp_compute_settings(project, credentials_file):
    """What google.cloud.gcp_compute needs to list our VMs (the content of its own inventory file)."""
    return {
        "plugin": "google.cloud.gcp_compute",
        "projects": [project],
        "auth_kind": "serviceaccount",
        "service_account_file": credentials_file,
        "filters": ["labels.vm:*"], 
        "hostnames": ["name"],
        "vars_prefix": "gcp_",
        "keyed_groups": [{"key": "labels.vm", "prefix": "vm"}],
        "compose": {
            "vm": "labels.vm",
            "private_ip": "networkInterfaces[0].networkIP",
            "public_ip": "(networkInterfaces[0].accessConfigs | default([{}]))[0].natIP | default('')",
        },
    }


def vm_settings(config, name):
    """A VM of config.json with vms.defaults filled in: its own values replace the defaults, its roles are added."""
    defaults = config["vms"]["defaults"]
    vm = config["vms"]["instances"][name]
    settings = {"bastion": False, "services": [], "secrets": []}
    settings.update(defaults)
    settings.update(vm)
    settings["roles"] = list(dict.fromkeys(defaults.get("roles", []) + vm.get("roles", [])))
    return settings


def groups_of(config, name, vm):
    """The groups of a VM: the role it plays, by what config.json says about it."""
    groups = []
    if vm["bastion"]:
        groups.append("bastion")
    if vm["services"]:
        groups.append("app") 
    tls = config.get("tls", {})
    if tls.get("domain") and name == tls.get("vm"):
        groups.append("frontend") 
    return groups


def connection(ssh, vm, private_ip, bastion_ip):
    """How Ansible reaches the VM over SSH, with the key of this run (role ssh_access): its private half is only
    in YOUR ssh-agent, its public half in ssh.access_public_key_file (IdentitiesOnly: the agent's matching key is
    the only one tried). The bastion directly, on ssh.bastion_port. The others through it: "ssh -W" is what
    ProxyJump runs, written out so the jump gets its own options; the bastion only passes the bytes on."""
    key = os.path.expanduser(ssh["access_public_key_file"])
    args = ["-o StrictHostKeyChecking=accept-new", "-o IdentitiesOnly=yes", "-o IdentityFile={}".format(key)]
    settings = {
        "ansible_user": ssh["user"],
        "ansible_ssh_retries": 5, 
        "ansible_pipelining": True, 
        "ansible_python_interpreter": "/usr/bin/python3", 
    }
    if vm["bastion"]:
        settings.update(ansible_host=bastion_ip, ansible_port=ssh["bastion_port"])
    else:
        jump = "ssh -W %h:%p -q -p {} -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o IdentityFile={} {}@{}".format(
            ssh["bastion_port"], key, ssh["user"], bastion_ip)
        settings["ansible_host"] = private_ip
        args.append('-o ProxyCommand="{}"'.format(jump))
    settings["ansible_ssh_common_args"] = " ".join(args)
    return settings

# CloudSQL
SQLADMIN_URL = "https://sqladmin.googleapis.com/v1/projects/{project}/instances/{instance}"

def cloudsql_instance(project, name, credentials_file):
    """The Cloud SQL instance as the Cloud SQL Admin API describes it, or {} while it does not exist."""
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    credentials = service_account.Credentials.from_service_account_file(
        credentials_file, scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    response = AuthorizedSession(credentials).get(SQLADMIN_URL.format(project=project, instance=name))
    if response.status_code == 404:
        return {}
    response.raise_for_status()
    return response.json()

def private_address(instance):
    """The private IP of a Cloud SQL instance (its "ipAddresses" of type PRIVATE), or "" if it has none."""
    return next((a["ipAddress"] for a in instance.get("ipAddresses", []) if a.get("type") == "PRIVATE"), "")

# VMs
def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


class InventoryModule(BaseInventoryPlugin):
    NAME = "citybikes.infra.gcp"

    def verify_file(self, path):
        return super().verify_file(path) and path.endswith(("citybikes.yml", "citybikes.yaml"))

    def parse(self, inventory, loader, path, cache=True):
        super().parse(inventory, loader, path, cache)
        self._read_config_data(path)
        config_file = os.path.abspath(
            self.get_option("config") or os.path.join(os.path.dirname(path), "..", "..", "infra", "config.json")
        )
        
        credentials_file = self.get_option("credentials_file")
        config = read_json(config_file)
        project = read_json(credentials_file)["project_id"]

        self._list_vms(project, credentials_file)
        self.inventory.set_variable("all", "citybikes_config_file", config_file)

        database = cloudsql_instance(project, config["prefix"] + "-pg", credentials_file)
        self.inventory.set_variable("all", "citybikes_db_host", private_address(database))

        self._describe_vms(config)

    def _list_vms(self, project, credentials_file):
        """google.cloud.gcp_compute adds the hosts, from its settings in a temporary file (as plugin "auto" calls it)."""
        gcp_compute = inventory_loader.get("google.cloud.gcp_compute")
        if gcp_compute is None:
            raise AnsibleParserError("The collection google.cloud is missing: install citybikes.infra again")
        with tempfile.NamedTemporaryFile("w", suffix=".gcp.yml") as settings:
            json.dump(gcp_compute_settings(project, credentials_file), settings)
            settings.flush()
            gcp_compute.parse(self.inventory, self.loader, settings.name, cache=False)

    def _describe_vms(self, config):
        """Groups, settings and connection of every VM of config.json that exists in GCP."""
        host_of = {}
        for host in self.inventory.hosts:
            vm = self.inventory.get_host(host).get_vars().get("vm")
            if vm in config["vms"]["instances"]:
                host_of[vm] = host
            elif vm:
                display.warning("%s has the label vm=%s, which is not in config.json: left out" % (host, vm))

        vms = {name: vm_settings(config, name) for name in config["vms"]["instances"]}
        bastions = [name for name, vm in vms.items() if vm["bastion"] and name in host_of]
        bastion_ip = self.inventory.get_host(host_of[bastions[0]]).get_vars()["public_ip"] if len(bastions) == 1 else None

        for name, host in host_of.items():
            for group in groups_of(config, name, vms[name]):
                self.inventory.add_group(group)
                self.inventory.add_child(group, host)
            self.inventory.set_variable(host, "citybikes_vm", vms[name])
            if bastion_ip:
                private_ip = self.inventory.get_host(host).get_vars()["private_ip"]
                for key, value in connection(config["ssh"], vms[name], private_ip, bastion_ip).items():
                    self.inventory.set_variable(host, key, value)