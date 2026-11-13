import re

import yaml

from ansible.errors import AnsibleFilterError

REFERENCE = re.compile(r"\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)((?::?[-?])[^}]*)?\}")


class _Dumper(yaml.SafeDumper):
    pass


def _represent_str(dumper, value):
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


_Dumper.add_representer(str, _represent_str)


def _substitute(node, values):
    if isinstance(node, str):
        def replace(match):
            name = match.group(1)
            if name is None or name not in values:
                return match.group(0)
            return values[name]
        return REFERENCE.sub(replace, node)
    if isinstance(node, list):
        return [_substitute(item, values) for item in node]
    if isinstance(node, dict):
        return {key: _substitute(item, values) for key, item in node.items()}
    return node


def _drop_dependencies(service, kept):
    depends = service.get("depends_on")
    if isinstance(depends, list):
        service["depends_on"] = [name for name in depends if name in kept]
    elif isinstance(depends, dict):
        service["depends_on"] = {name: rule for name, rule in depends.items() if name in kept}
    if "depends_on" in service and not service["depends_on"]:
        del service["depends_on"]


def compose_render(source, values, profiles):
    try:
        document = yaml.safe_load(str(source))
    except yaml.YAMLError as e:
        raise AnsibleFilterError("compose_render: %s" % e)
    if not isinstance(document, dict) or not isinstance(document.get("services"), dict):
        raise AnsibleFilterError("compose_render: no services")
    values = {str(k): str(v) for k, v in dict(values).items()}
    wanted = set(profiles)
    services = {}
    for name, service in document["services"].items():
        service = dict(service or {})
        declared = service.pop("profiles", None)
        if declared is None or wanted.intersection(declared):
            services[name] = service
    for service in services.values():
        _drop_dependencies(service, services)
    document["services"] = services
    document = _substitute(document, values)
    return yaml.dump(document, Dumper=_Dumper, sort_keys=False, default_flow_style=False, width=4096, allow_unicode=True)


class FilterModule:
    def filters(self):
        return {"compose_render": compose_render}
