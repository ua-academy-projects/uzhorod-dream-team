# oleksiy_lohoyda.weather

Configures the Weather Forecast VMs on Google Cloud and deploys the application.
Terraform creates the VMs; this collection configures them.

## Requirements

- `sudo apt install ansible python3-jsonschema python3-google-auth`
- Docker and the `gcloud` CLI on the operator machine
- `~/.config/weather-forecast/local.env` with `PROJECT_ID` and `GOOGLE_APPLICATION_CREDENTIALS`

## Run

```bash
cd weather-forecast/infra/ansible
set -a; source ~/.config/weather-forecast/local.env; set +a
ansible-playbook oleksiy_lohoyda.weather.site
```

## Content

| Name | Kind | Does |
| --- | --- | --- |
| `gcp_vms` | inventory plugin | running VMs from the config, reached through the bastion |
| `site` | playbook | runs all roles in order |
| `validate_config` | role | checks the config against `files/deployment.schema.json` |
| `base` | role | package upgrades and base packages |
| `ops_agent` | role | Google Cloud Ops Agent |
| `docker` | role | Docker with the VPC MTU |
| `container` | role | one application container, chosen by `container_service` |
| `database` | role | PGMQ, hstore, migrations, roles and grants |
| `certbot` | role | Let's Encrypt certificate and renewal timer |

The bastion is configured by cloud-init and is not managed here.
