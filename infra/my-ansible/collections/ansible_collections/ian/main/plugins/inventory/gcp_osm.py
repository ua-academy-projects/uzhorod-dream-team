# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-2.0-or-later
"""Inventory ian.main.gcp_osm: thin wrapper over google.cloud.gcp_compute that injects projects from config.json."""

from __future__ import annotations

DOCUMENTATION = r"""
name: gcp_osm
author: ian
version_added: "1.0.0"
short_description: google.cloud.gcp_compute with the project taken from config.json
description:
  - Everything is done by C(google.cloud.gcp_compute); all of its options (filters, hostnames, compose, auth_kind, ...) work unchanged.
  - The only difference is that C(projects) is not specified in the file but taken from C(project_id) in C(config.json) (lookup C(ian.main.osm_config)).
  - gcp_compute does not template C(projects) itself and does not read the project from C(gcloud config), so without this plugin the project name would have to be duplicated.
options:
  plugin:
    description: Must be C(ian.main.gcp_osm).
    required: true
    choices: ['ian.main.gcp_osm']
"""

from ansible.errors import AnsibleError
from ansible.plugins.inventory import BaseInventoryPlugin
from ansible.plugins.loader import inventory_loader, lookup_loader


class InventoryModule(BaseInventoryPlugin):
    NAME = "ian.main.gcp_osm"

    def verify_file(self, path):
        return super().verify_file(path) and path.endswith(("gcp_osm.yml", "gcp_osm.yaml"))

    def parse(self, inventory, loader, path, cache=True):
        project = lookup_loader.get("ian.main.osm_config").run(["project_id"])[0]
        if not project:
            raise AnsibleError("config.json: project_id is empty")

        # the real gcp_compute, loaded through the plugin loader so its option definitions are in place;
        # its config reader insists that `plugin:` in the file is one of its names, so it is told ours
        base = inventory_loader.get("google.cloud.gcp_compute")
        base._redirected_names = [self.NAME]
        read = base._read_config_data

        def read_with_project(p):
            data = read(p)
            base.set_option("projects", [project])
            return data

        base._read_config_data = read_with_project
        base.parse(inventory, loader, path, cache)
