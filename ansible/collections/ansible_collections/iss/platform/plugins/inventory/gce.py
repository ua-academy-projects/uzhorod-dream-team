from __future__ import annotations

DOCUMENTATION = r"""
name: gce
short_description: Google Compute Engine instances reached through one SSH bastion
description:
  - Lists the instances of one project in the given zones through the Compute Engine API, filtered by labels.
  - Groups hosts by the values of the given labels; characters not allowed in group names become C(_).
  - O(private_key_file), O(known_hosts_file) and O(jump_user) go into SSH arguments and must not contain spaces, quotes or shell characters.
  - Sets the SSH connection variables, with every host except the bastion reached through a ProxyCommand to the bastion.
  - Instances that are not RUNNING are skipped with a warning.
  - The inventory file name must end with C(gce.yml) or C(gce.yaml).
version_added: 1.0.0
author:
  - ISS position tracker (@iss-position-tracker)
requirements:
  - google-auth
  - requests
options:
  plugin:
    description: Marks this file as an inventory of this plugin.
    type: str
    required: true
    choices: [iss.platform.gce]
  project:
    description: GCP project ID.
    type: str
    required: true
  zones:
    description: Zones to list instances in.
    type: list
    elements: str
    required: true
  auth_kind:
    description: Authentication method.
    type: str
    choices: [serviceaccount]
    default: serviceaccount
  service_account_file:
    description: Service account JSON key file.
    type: path
    required: true
    env:
      - name: GCP_SERVICE_ACCOUNT_FILE
  filters:
    description: Labels an instance must have, as label name to value.
    type: dict
    default: {}
  group_labels:
    description: Label names whose values become group names.
    type: list
    elements: str
    default: []
  bastion_label:
    description: Label that marks the bastion.
    type: str
    required: true
  bastion_value:
    description: Value of O(bastion_label) on the bastion.
    type: str
    required: true
  admin_user:
    description: SSH user on every host (C(ansible_user)).
    type: str
    required: true
  jump_user:
    description: User on the bastion for the ProxyCommand of the other hosts.
    type: str
    required: true
  ssh_port:
    description: SSH port of the bastion; the other hosts use 22.
    type: int
    default: 22
  private_key_file:
    description: SSH private key for every host and for the jump.
    type: path
    required: true
  known_hosts_file:
    description: known_hosts file used for every host and for the jump.
    type: path
    required: true
  api_endpoint:
    description: Compute Engine API endpoint.
    type: str
    default: https://compute.googleapis.com
"""

EXAMPLES = r"""
plugin: iss.platform.gce
project: my-project
zones: [changeme]
filters:
  iss-prefix: iss
group_labels: [iss-key, iss-role]
bastion_label: iss-role
bastion_value: bastion
admin_user: iss-admin
jump_user: jump
ssh_port: 2222
private_key_file: ~/.ssh/iss_gcp_ed25519
known_hosts_file: ~/.ssh/iss_gcp/known_hosts
"""

import shlex

from ansible.errors import AnsibleParserError
from ansible.inventory.group import to_safe_group_name
from ansible.plugins.inventory import BaseInventoryPlugin
from ansible.utils.display import Display
from ansible_collections.iss.platform.plugins.module_utils.gce import (
    HAS_GOOGLE,
    authorized_session,
    compute_url,
    list_all,
)

OPTION_NAMES = (
    "project",
    "zones",
    "service_account_file",
    "filters",
    "group_labels",
    "bastion_label",
    "bastion_value",
    "admin_user",
    "jump_user",
    "ssh_port",
    "private_key_file",
    "known_hosts_file",
    "api_endpoint",
)

display = Display()


def label_filter(filters):
    if not filters:
        return None
    return " AND ".join('labels.%s = "%s"' % (key, value) for key, value in filters.items())


def first_nic(instance):
    nics = instance.get("networkInterfaces") or [{}]
    return nics[0]


def internal_ip(instance):
    return first_nic(instance).get("networkIP")


def external_ip(instance):
    configs = first_nic(instance).get("accessConfigs") or [{}]
    return configs[0].get("natIP")


def check_plain(options, names):
    for name in names:
        value = str(options[name])
        if not value or shlex.quote(value) != value:
            raise AnsibleParserError("%s must not be empty or contain spaces, quotes or shell characters: %r" % (name, value))


def build_hosts(instances, options, warn):
    check_plain(options, ("known_hosts_file", "private_key_file", "jump_user"))
    label, value = options["bastion_label"], options["bastion_value"]
    running, stopped_bastions = [], []
    for instance in instances:
        if instance.get("status") == "RUNNING":
            running.append(instance)
        else:
            warn("skipping %s: status %s" % (instance.get("name"), instance.get("status")))
            if instance.get("labels", {}).get(label) == value:
                stopped_bastions.append(instance.get("name"))
    if not running:
        raise AnsibleParserError(
            "no RUNNING instances in project %s, zones %s match %s"
            % (options["project"], ", ".join(options["zones"]), label_filter(options["filters"]) or "no filter")
        )

    bastions = [i for i in running if i.get("labels", {}).get(label) == value]
    if len(bastions) != 1:
        raise AnsibleParserError(
            "expected exactly one bastion (%s=%s), found %d: %s%s"
            % (
                label,
                value,
                len(bastions),
                ", ".join(i["name"] for i in bastions) or "none",
                "; not running: %s" % ", ".join(stopped_bastions) if stopped_bastions else "",
            )
        )
    for instance in running:
        if not internal_ip(instance):
            raise AnsibleParserError("%s has no internal IP" % instance.get("name"))
    bastion = bastions[0]
    bastion_ip = external_ip(bastion)
    if not bastion_ip:
        raise AnsibleParserError("bastion %s has no external IP" % bastion["name"])

    ssh_opts = "-o IdentitiesOnly=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=accept-new" % options["known_hosts_file"]
    proxy = "ssh %s -i %s -p %d -W %%h:%%p %s@%s" % (
        ssh_opts,
        options["private_key_file"],
        options["ssh_port"],
        options["jump_user"],
        bastion_ip,
    )

    hosts = {}
    for instance in running:
        is_bastion = instance is bastion
        labels = instance.get("labels", {})
        groups = [to_safe_group_name(labels[name], force=True, silent=True) for name in options["group_labels"] if labels.get(name)]
        hosts[instance["name"]] = {
            "groups": groups,
            "vars": {
                "gce_internal_ip": internal_ip(instance),
                "ansible_host": bastion_ip if is_bastion else internal_ip(instance),
                "ansible_user": options["admin_user"],
                "ansible_port": options["ssh_port"] if is_bastion else 22,
                "ansible_ssh_private_key_file": options["private_key_file"],
                "ansible_ssh_common_args": ssh_opts if is_bastion else "%s -o ProxyCommand='%s'" % (ssh_opts, proxy),
            },
        }
    return hosts


class InventoryModule(BaseInventoryPlugin):
    NAME = "iss.platform.gce"

    def verify_file(self, path):
        return super().verify_file(path) and path.endswith(("gce.yml", "gce.yaml"))

    def parse(self, inventory, loader, path, cache=False):
        super().parse(inventory, loader, path, cache)
        self._read_config_data(path)
        if not HAS_GOOGLE:
            raise AnsibleParserError("iss.platform.gce needs google-auth and requests")
        options = {name: self.get_option(name) for name in OPTION_NAMES}

        try:
            session = authorized_session(options["service_account_file"])
        except (OSError, ValueError) as e:
            raise AnsibleParserError("cannot read service account file %s: %s" % (options["service_account_file"], e))
        query = label_filter(options["filters"])
        params = {"filter": query} if query else {}
        instances = []
        try:
            for zone in options["zones"]:
                url = compute_url(options["api_endpoint"], "projects", options["project"], "zones", zone, "instances")
                instances.extend(list_all(session, url, params))
        except Exception as e:
            raise AnsibleParserError("GCE API request failed: %s" % e)

        for name, host in build_hosts(instances, options, display.warning).items():
            self.inventory.add_host(name)
            for group in host["groups"]:
                self.inventory.add_group(group)
                self.inventory.add_child(group, name)
            for key, value in host["vars"].items():
                self.inventory.set_variable(name, key, value)
