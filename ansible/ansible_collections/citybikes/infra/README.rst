citybikes.infra
===============

Everything **on** the VMs of CityBikes History in GCP (Terraform in ``infra/`` builds the VMs).
Ansible never talks to Terraform: what it needs comes from ``infra/config.json``, the rest from GCP.

Install it as a package (with its dependencies, from ``galaxy.yml``), and again after every change:

.. code-block:: bash

   cd ansible
   pip install -r requirements.txt                                                  # once
   ansible-galaxy collection install ./ansible_collections/citybikes/infra --force  # after every change

Run, after ``source infra/bootstrap/terraform.env`` (the key of the service account):

.. code-block:: bash

   ansible-inventory -i inventory/citybikes.yml --graph
   ansible-playbook  -i inventory/citybikes.yml citybikes.infra.site

Inventory: plugin ``citybikes.infra.gcp`` (``ansible-doc -t inventory citybikes.infra.gcp``), a wrapper
around ``google.cloud.gcp_compute`` set up from ``config.json``. Groups, by the role a VM plays:
``bastion`` (the way in), ``app`` (runs services of the application), ``frontend`` (serves the site).
Each VM's settings (``citybikes_vm``), how to reach it, and ``citybikes_config_file``.

The first role of every playbook, ``config_validate``, loads ``config.json`` into the variable ``config``
(``include_vars``) and checks it: JSON Schema, every VM exists, the parts fit together.
