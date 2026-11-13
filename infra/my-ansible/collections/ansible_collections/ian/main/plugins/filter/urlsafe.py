# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-2.0-or-later
"""Filter plugin ian.main.urlsafe: escapes a string for insertion into a URL (password in postgres:// or amqp://)."""

from __future__ import annotations

DOCUMENTATION = r"""
name: urlsafe
author: ian
version_added: "1.0.0"
short_description: Escapes a string for safe insertion into a URL
description:
  - Encodes all unsafe characters, including C(/), C(@), C(:), C(?), C(#) and space.
  - The built-in C(urlencode) leaves C(/) as is, so a password containing a slash breaks the URL.
options:
  _input:
    description: A string (for example a password).
    type: str
    required: true
"""

EXAMPLES = r"""
- ansible.builtin.debug:
    msg: "postgres://pgmq:{{ queue_env_pgmq_password | ian.main.urlsafe }}@{{ queue_env_db_host }}:5432/pgmq"
"""

RETURN = r"""
_value:
  description: The escaped string.
  type: str
"""

from urllib.parse import quote

from ansible.errors import AnsibleFilterTypeError


def urlsafe(value):
    if value is None or isinstance(value, (dict, list, tuple, set)):
        raise AnsibleFilterTypeError(f"urlsafe expects a string, got {type(value).__name__}")
    return quote(str(value), safe="")


class FilterModule:
    def filters(self):
        return {"urlsafe": urlsafe}
