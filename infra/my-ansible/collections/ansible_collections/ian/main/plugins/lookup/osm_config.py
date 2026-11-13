# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-2.0-or-later
"""Lookup plugin ian.main.osm_config: reads values from infra/config.json by dotted key."""

from __future__ import annotations

DOCUMENTATION = r"""
name: osm_config
author: ian
version_added: "1.0.0"
short_description: Reads a value from config.json by a dot-separated path
description:
  - The single point through which roles access C(infra/config.json).
  - The key consists of dot-separated segments. A numeric segment indexes into a list.
  - If the key is missing and C(default) is not set, fails with a clear message about which part of the path was not found.
options:
  _terms:
    description: One or more keys, for example C(services.fetcher.ports.0).
    required: true
    type: list
    elements: str
  path:
    description:
      - Path to config.json.
      - By default, C(../config.json) relative to the directory containing ansible.cfg.
    type: path
    env:
      - name: OSM_CONFIG
  default:
    description: Value returned if the key is missing. Without it, a missing key is an error.
    type: raw
"""

EXAMPLES = r"""
- name: Single key
  ansible.builtin.debug:
    msg: "{{ lookup('ian.main.osm_config', 'services.fetcher.ports.0') }}"

- name: Whole section (dictionary)
  ansible.builtin.set_fact:
    fetcher_env: "{{ lookup('ian.main.osm_config', 'services.fetcher.env') }}"

- name: With a default
  ansible.builtin.debug:
    msg: "{{ lookup('ian.main.osm_config', 'services.nope.port', default=0) }}"
"""

RETURN = r"""
_raw:
  description: The values found, one per key.
  type: list
  elements: raw
"""

import json
import os

from ansible import constants as C
from ansible.errors import AnsibleLookupError
from ansible.plugins.lookup import LookupBase

_MISSING = object()


def _walk(data, key):
    """Walks a dotted key. Returns _MISSING if the path breaks off somewhere."""
    node = data
    for part in key.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            return _MISSING
    return node


class LookupModule(LookupBase):
    def _config_path(self):
        explicit = self.get_option("path")
        if explicit:
            return explicit
        # CONFIG_FILE = the ansible.cfg currently in use. config.json lives one level up.
        if not C.CONFIG_FILE:
            raise AnsibleLookupError("ansible.cfg not found, set path or the OSM_CONFIG variable")
        return os.path.normpath(os.path.join(os.path.dirname(C.CONFIG_FILE), "..", "config.json"))

    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)
        path = self._config_path()
        default = self.get_option("default")

        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except OSError as exc:
            raise AnsibleLookupError(f"failed to read {path}: {exc}") from exc
        except ValueError as exc:
            raise AnsibleLookupError(f"{path} is not valid JSON: {exc}") from exc

        result = []
        for key in terms:
            value = _walk(data, key)
            if value is _MISSING:
                if default is None:
                    raise AnsibleLookupError(f"key '{key}' not found in {path}")
                value = default
            result.append(value)
        return result
