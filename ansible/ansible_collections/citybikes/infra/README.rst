citybikes.infra
===============

Everything **on** the VMs of CityBikes History in GCP (Terraform in ``infra/`` builds the VMs).

Run from ``ansible/`` (it has the ``ansible.cfg``):

.. code-block:: bash

   pip install -r requirements.txt                       # once
   ansible-galaxy collection install -r requirements.yml # once
   ansible-playbook citybikes.infra.ping                 # the collection is found