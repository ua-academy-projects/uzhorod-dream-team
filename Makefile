SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.NOTPARALLEL:

VENV := $(CURDIR)/.venv
export DATAMONITOR_ROOT := $(CURDIR)
export DATAMONITOR_CONFIG := $(CURDIR)/config.json
export ANSIBLE_CONFIG := $(CURDIR)/ansible.cfg
PLAYBOOK := $(VENV)/bin/ansible-playbook
INVENTORY ?= $(CURDIR)/.deploy/inventory.gcp.yaml
LOCAL_PLAYBOOK = $(PLAYBOOK) -i localhost, -e ansible_python_interpreter=$(VENV)/bin/python -e 'deployment_inventory=$(INVENTORY)'
# Documentation-only commits don't create a new application release.
RELEASE ?= $(CURDIR)/.deploy/releases/$(shell git log -1 --format=%H -- DataFetcher ':(exclude)DataFetcher/**/*.md' ':(exclude)DataFetcher/*.md').json

.PHONY: help setup validate configure start build deploy deploy-ui inventory

help:
	@echo 'make setup      — install local Ansible dependencies once'
	@echo 'make deploy     — start VMs, build/reuse the release, deploy all services'
	@echo 'make deploy-ui  — start VMs, build/reuse the release, update UI only'
	@echo 'make validate   — check config.json locally'
	@echo 'make configure  — validate config and generate the dynamic inventory source'
	@echo 'make start      — start existing stopped VMs'
	@echo 'make build      — build/reuse the application release'
	@echo 'make inventory  — list running GCP hosts'
	@echo 'make deploy RELEASE=/absolute/path/release.json — deploy an existing release'

setup:
	python3 -m venv "$(VENV)"
	"$(VENV)/bin/python" -m pip install -r ansible/requirements-controller.txt
	"$(VENV)/bin/ansible-galaxy" collection install -r ansible/requirements.yaml -p "$(VENV)/collections"

validate:
	$(LOCAL_PLAYBOOK) ansible/playbooks/validate.yaml

start:
	$(LOCAL_PLAYBOOK) ansible/playbooks/start.yaml

configure:
	$(LOCAL_PLAYBOOK) ansible/playbooks/configure.yaml

build:
	$(LOCAL_PLAYBOOK) ansible/playbooks/build.yaml -e 'build_release_file=$(RELEASE)'

deploy:
	$(LOCAL_PLAYBOOK) ansible/playbooks/release.yaml -e 'build_release_file=$(RELEASE)'
	$(PLAYBOOK) -i "$(INVENTORY)" ansible/playbooks/site.yaml -e '@$(RELEASE)'

deploy-ui:
	$(LOCAL_PLAYBOOK) ansible/playbooks/release.yaml -e 'build_release_file=$(RELEASE)'
	$(PLAYBOOK) -i "$(INVENTORY)" ansible/playbooks/wait.yaml --limit ui
	$(PLAYBOOK) -i "$(INVENTORY)" ansible/playbooks/ui.yaml -e '@$(RELEASE)'

inventory: configure
	"$(VENV)/bin/ansible-inventory" -i "$(INVENTORY)" --graph
