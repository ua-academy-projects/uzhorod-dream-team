
DOCUMENTATION = r"""
module: gcp_sql_instance
short_description: Is there a Cloud SQL instance of this name, and its private IP (a wrapper around google.cloud.gcp_sql_instance_info)
description:
  - Lists the Cloud SQL instances of the project with google.cloud.gcp_sql_instance_info and picks the one of this name.
  - Returns C(exists) and C(private_ip) (empty while it does not exist or has no private IP). Changes nothing.
  - Who we are comes from GOOGLE_APPLICATION_CREDENTIALS (a key file), the project is the one of the key.
options:
  name:
    description: The instance, e.g. citybikes-pg.
    type: str
    required: true
requirements: [google-auth, requests]
"""