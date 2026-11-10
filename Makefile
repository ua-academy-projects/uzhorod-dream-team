SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.NOTPARALLEL:

VENV := $(CURDIR)/.venv
export ANSIBLE_COLLECTIONS_PATH := $(VENV)/collections
export ANSIBLE_LOCAL_TEMP := $(VENV)/tmp
PLAYBOOK := $(VENV)/bin/ansible-playbook
LOCAL_PLAYBOOK := $(PLAYBOOK) -i localhost, -e ansible_python_interpreter=$(VENV)/bin/python
INVENTORY ?= ansible/inventory.gcp.yaml
RELEASE ?= $(CURDIR)/.deploy/releases/$(shell git log -1 --format=%H -- DataFetcher).json

.PHONY: help setup validate start build deploy deploy-ui inventory

help:
	@echo 'make setup      — install local Ansible dependencies once'
	@echo 'make deploy     — start VMs, build/reuse the release, deploy all services'
	@echo 'make deploy-ui  — start VMs, build/reuse the release, update UI only'
	@echo 'make validate   — check config.json locally'
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

build:
	@mkdir -p "$(dir $(RELEASE))"
	@if test -s "$(RELEASE)"; then \
	  echo 'Using existing release: $(RELEASE)'; \
	else \
	  $(LOCAL_PLAYBOOK) ansible/playbooks/build.yaml -e 'build_release_file=$(RELEASE)'; \
	fi

deploy:
	$(MAKE) start
	$(MAKE) build
	$(PLAYBOOK) -i "$(INVENTORY)" ansible/playbooks/site.yaml -e '@$(RELEASE)'

deploy-ui:
	$(MAKE) start
	$(MAKE) build
	$(PLAYBOOK) -i "$(INVENTORY)" ansible/playbooks/wait.yaml --limit ui
	$(PLAYBOOK) -i "$(INVENTORY)" ansible/playbooks/ui.yaml -e '@$(RELEASE)'

inventory:
	"$(VENV)/bin/ansible-inventory" -i "$(INVENTORY)" --graph
