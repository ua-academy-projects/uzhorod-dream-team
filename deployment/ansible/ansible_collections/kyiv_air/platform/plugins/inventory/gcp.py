import json
import os
import tempfile

import yaml

from ansible.errors import AnsibleParserError
from ansible.plugins.inventory import BaseInventoryPlugin
from ansible.plugins.loader import inventory_loader

OWN_OPTIONS = ("plugin",)


class InventoryModule(BaseInventoryPlugin):
    NAME = "kyiv_air.platform.gcp"

    def verify_file(self, path):
        return super().verify_file(path) and path.endswith((".yml", ".yaml"))

    def parse(self, inventory, loader, path, cache=True):
        super().parse(inventory, loader, path)

        config_path = os.environ.get("DEPLOYMENT_CONFIG")
        if not config_path:
            raise AnsibleParserError("Set DEPLOYMENT_CONFIG to the path of the deployment config.")
        try:
            with open(config_path, encoding="utf-8") as handle:
                cfg = json.load(handle)
            project = cfg["google"]["project_id"]
            zone = cfg["google"]["zone"]
        except (OSError, KeyError, ValueError) as error:
            raise AnsibleParserError(f"Cannot read the deployment config: {error}") from error
        prefix = cfg.get("vm", {}).get("name_prefix", "kyiv-air")

        with open(path, encoding="utf-8") as handle:
            settings = {key: value for key, value in yaml.safe_load(handle).items() if key not in OWN_OPTIONS}
        settings.update(
            plugin="google.cloud.gcp_compute",
            projects=[project],
            zones=[zone],
            filters=[f"name = {prefix}-*"],
        )

        gcp = inventory_loader.get("google.cloud.gcp_compute")
        with tempfile.NamedTemporaryFile("w", suffix=".gcp.yml", delete=False) as handle:
            yaml.safe_dump(settings, handle)
        try:
            gcp.parse(inventory, loader, handle.name, cache)
        finally:
            os.unlink(handle.name)
