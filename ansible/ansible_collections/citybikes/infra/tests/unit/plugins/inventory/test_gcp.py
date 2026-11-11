"""Unit tests of the inventory plugin citybikes.infra.gcp, without GCP (gcp_compute and the inventory are faked).
Run from ansible/:  python -m pytest ansible_collections/citybikes/infra/tests/unit"""

import importlib.util
import os
import unittest
from unittest import mock

import yaml

# the plugin under test, loaded straight from its file (no package lookup: works with any sys.path)
PLUGIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 4, "plugins", "inventory", "gcp.py")
spec = importlib.util.spec_from_file_location("gcp", PLUGIN_FILE)
gcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gcp)

CONFIG = {
    "prefix": "citybikes",
     "ssh": {"user": "citybikes", "bastion_port": 505, "access_public_key_file": "~/.ssh/access.pub", "key_ttl_minutes": 15},
    "tls": {"vm": "ui", "domain": "example.org"},
    "vms": {
        "defaults": {"machine_type": "e2-small", "disk_size_gb": 10, "cloud_logging": True, "roles": ["roles/logging.logWriter"]},
        "instances": {
            "db": {"host": 50, "disk_size_gb": 20, "services": ["redis"], "roles": ["roles/extra"]},
            "ui": {"host": 53, "services": ["ui", "cloudflared"], "cloud_logging": False},
            "bastion": {"host": 54, "services": [], "bastion": True, "secrets": ["internal-ssh-key"]},
        },
    },
}


class FakeHost:
    def __init__(self, host_vars):
        self.vars = host_vars

    def get_vars(self):
        return self.vars


class FakeInventory:
    """Just enough of Ansible's inventory: hosts with their vars, groups."""

    def __init__(self, hosts):
        self.hosts = {name: FakeHost(dict(v)) for name, v in hosts.items()}
        self.groups, self.all_vars = {}, {}

    def get_host(self, name):
        return self.hosts[name]

    def add_group(self, group):
        self.groups.setdefault(group, [])

    def add_child(self, group, host):
        self.groups[group].append(host)

    def set_variable(self, name, key, value):
        (self.all_vars if name == "all" else self.hosts[name].vars)[key] = value


def listed(vm, private_ip, public_ip=""):
    """A host as gcp_compute adds it (the variables of our "compose")."""
    return {"vm": vm, "private_ip": private_ip, "public_ip": public_ip}


class SettingsTests(unittest.TestCase):
    def test_gcp_compute_lists_only_our_vms_with_the_key(self):
        s = gcp.gcp_compute_settings("proj", "/keys/terraform.json")
        self.assertEqual(s["plugin"], "google.cloud.gcp_compute")
        self.assertEqual((s["projects"], s["service_account_file"]), (["proj"], "/keys/terraform.json"))
        self.assertEqual(s["filters"], ["labels.vm:*"])
        self.assertEqual(s["compose"]["vm"], "labels.vm")

    def test_own_values_replace_the_defaults_roles_are_added(self):
        db = gcp.vm_settings(CONFIG, "db")
        self.assertEqual((db["machine_type"], db["disk_size_gb"]), ("e2-small", 20))
        self.assertEqual(db["roles"], ["roles/logging.logWriter", "roles/extra"])
        self.assertFalse(gcp.vm_settings(CONFIG, "ui")["cloud_logging"])
        self.assertEqual(gcp.vm_settings(CONFIG, "ui")["secrets"], [])

    def test_groups_by_what_runs(self):
        settings = {name: gcp.vm_settings(CONFIG, name) for name in CONFIG["vms"]["instances"]}
        self.assertEqual(gcp.groups_of(CONFIG, "bastion", settings["bastion"]), ["bastion"])
        self.assertEqual(gcp.groups_of(CONFIG, "db", settings["db"]), ["app"])
        self.assertEqual(gcp.groups_of(CONFIG, "ui", settings["ui"]), ["app", "frontend"])


class DatabaseTests(unittest.TestCase):
    def test_the_private_ip_of_the_instance(self):
        instance = {"ipAddresses": [{"type": "OUTGOING", "ipAddress": "34.5.6.7"}, {"type": "PRIVATE", "ipAddress": "10.21.0.3"}]}
        self.assertEqual(gcp.private_address(instance), "10.21.0.3")

    def test_no_instance_or_no_private_ip_gives_empty(self):
        self.assertEqual(gcp.private_address({}), "")
        self.assertEqual(gcp.private_address({"ipAddresses": [{"type": "PRIMARY", "ipAddress": "34.5.6.7"}]}), "")


class ConnectionTests(unittest.TestCase):
    KEY = "-o IdentityFile=" + os.path.expanduser("~/.ssh/access.pub")

    def test_the_bastion_directly_on_its_port_with_the_key_of_this_run(self):
        c = gcp.connection(CONFIG["ssh"], {"bastion": True}, "10.20.0.54", "34.1.2.3")
        self.assertEqual((c["ansible_host"], c["ansible_port"]), ("34.1.2.3", 505))
        self.assertNotIn("ansible_ssh_private_key_file", c) 
        self.assertIn(self.KEY, c["ansible_ssh_common_args"])
        self.assertIn("-o IdentitiesOnly=yes", c["ansible_ssh_common_args"])
        self.assertNotIn("ProxyCommand", c["ansible_ssh_common_args"])

    def test_the_others_through_the_bastion_with_the_same_key(self):
        c = gcp.connection(CONFIG["ssh"], {"bastion": False}, "10.20.0.50", "34.1.2.3")
        self.assertEqual(c["ansible_host"], "10.20.0.50")
        self.assertNotIn("ansible_port", c)  
        self.assertNotIn("ansible_ssh_private_key_file", c)
        args = c["ansible_ssh_common_args"]
        self.assertEqual(args.count(self.KEY), 2) 
        self.assertIn('ProxyCommand="ssh -W %h:%p -q -p 505', args)
        self.assertIn("citybikes@34.1.2.3", args)
        self.assertNotIn("ForwardAgent", args) 


class PluginTests(unittest.TestCase):
    def plugin(self, hosts):
        plugin = gcp.InventoryModule.__new__(gcp.InventoryModule)
        plugin.inventory, plugin.loader = FakeInventory(hosts), None
        return plugin

    def test_gcp_compute_gets_its_settings_in_a_file(self):
        seen = {}

        class FakeGcpCompute:
            def parse(self, inventory, loader, path, cache):
                with open(path) as f:
                    seen.update(yaml.safe_load(f))

        plugin = self.plugin({})
        with mock.patch.object(gcp.inventory_loader, "get", return_value=FakeGcpCompute()) as get:
            plugin._list_vms("proj", "/keys/terraform.json")
        get.assert_called_once_with("google.cloud.gcp_compute")
        self.assertEqual(seen["projects"], ["proj"])

    def test_every_vm_gets_groups_settings_and_connection(self):
        plugin = self.plugin({
            "citybikes-db": listed("db", "10.20.0.50"),
            "citybikes-ui": listed("ui", "10.20.0.53"),
            "citybikes-bastion": listed("bastion", "10.20.0.54", "34.1.2.3"),
        })
        plugin._describe_vms(CONFIG)
        inv = plugin.inventory
        self.assertEqual(inv.groups, {"app": ["citybikes-db", "citybikes-ui"], "frontend": ["citybikes-ui"], "bastion": ["citybikes-bastion"]})
        db = inv.hosts["citybikes-db"].vars
        self.assertEqual(db["citybikes_vm"]["disk_size_gb"], 20)
        self.assertEqual(db["ansible_host"], "10.20.0.50")
        self.assertIn("citybikes@34.1.2.3", db["ansible_ssh_common_args"])

    def test_no_bastion_in_gcp_no_connection(self):
        plugin = self.plugin({"citybikes-db": listed("db", "10.20.0.50")})
        plugin._describe_vms(CONFIG)
        self.assertNotIn("ansible_host", plugin.inventory.hosts["citybikes-db"].vars)
        self.assertIn("citybikes_vm", plugin.inventory.hosts["citybikes-db"].vars)


if __name__ == "__main__":
    unittest.main()