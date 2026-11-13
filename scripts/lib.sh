#!/usr/bin/env bash

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${ISS_CONFIG:-$ROOT/config.json}

SECRETS=(
  RABBITMQ_USER POSTGRES_PASSWORD POSTGRES_HISTORY_PASSWORD POSTGRES_FETCHER_PASSWORD RABBITMQ_PASSWORD REDIS_PASSWORD
  CF_TUNNEL_TOKEN CLOUDFLARE_API_TOKEN LETSENCRYPT_STATE
)
GENERATED_SECRETS=(
  RABBITMQ_USER POSTGRES_PASSWORD POSTGRES_HISTORY_PASSWORD POSTGRES_FETCHER_PASSWORD RABBITMQ_PASSWORD REDIS_PASSWORD
)

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || die "$c is not installed"
  done
}

cfg() {
  [[ -f $CONFIG ]] || die "$CONFIG not found (cp config.example.json config.json)"
  jq -r "$1" < "$CONFIG"
}

project_id() {
  local id
  id=$(cfg '.project.id // ""') || exit 1
  [[ -n $id ]] || die "project.id is empty in config.json, run ./scripts/bootstrap.sh first"
  echo "$id"
}

sa_key_path() {
  local p abs root
  p=$(cfg '.access.sa_key_file // ""') || exit 1
  [[ -n $p ]] || die "access.sa_key_file is empty in config.json"
  [[ $p == \~/* ]] && p=$HOME/${p#\~/}
  abs=$(cd "$ROOT" && realpath -m -- "$p") || die "cannot resolve access.sa_key_file $p"
  root=$(realpath -- "$ROOT")
  if [[ $abs == "$root" || $abs == "$root"/* ]]; then
    die "SA key path $abs is inside the project $root; keep it outside, e.g. ../iss-gcp-keys/terraform.json"
  fi
  echo "$abs"
}

use_sa_key() {
  local key
  key=$(sa_key_path) || exit 1
  [[ -f $key ]] || die "SA key $key not found, run ./scripts/bootstrap.sh"
  export GOOGLE_APPLICATION_CREDENTIALS=$key
  export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=$key
}

ansible_venv() {
  local cache=${XDG_CACHE_HOME:-$HOME/.cache}/iss-ansible venv
  venv=$cache/venv
  if [[ ! -x $venv/bin/python ]]; then
    need python3
    python3 -c 'import ensurepip' 2>/dev/null || die "python3-venv is missing: sudo apt install python3-venv"
    mkdir -p "$cache"
    python3 -m venv "$venv" || die "cannot create $venv"
  fi
  if [[ ! -f $venv/.req-stamp || $ROOT/ansible/requirements.txt -nt $venv/.req-stamp ]]; then
    "$venv/bin/pip" install -q --upgrade pip || die "pip upgrade failed"
    "$venv/bin/pip" install -q -r "$ROOT/ansible/requirements.txt" || die "pip install failed"
    touch "$venv/.req-stamp"
  fi
  export PATH=$venv/bin:$PATH
  export ANSIBLE_CONFIG=$ROOT/ansible/ansible.cfg
  export ANSIBLE_COLLECTIONS_PATH=$cache/collections:$ROOT/ansible/collections
  export ISS_ANSIBLE_CACHE=$cache
  if [[ ! -f $cache/.galaxy-stamp || $ROOT/ansible/requirements.yml -nt $cache/.galaxy-stamp ]]; then
    ansible-galaxy collection install -r "$ROOT/ansible/requirements.yml" -p "$cache/collections" --force >/dev/null \
      || die "ansible-galaxy collection install failed"
    touch "$cache/.galaxy-stamp"
  fi
}

ISS_CONFIG_CHECKED=

config_check() {
  local out
  [[ -z $ISS_CONFIG_CHECKED ]] || return 0
  [[ -f $CONFIG ]] || die "$CONFIG not found (cp config.example.json config.json)"
  ansible_venv
  if ! out=$(check-jsonschema --schemafile "$ROOT/config.schema.json" "$CONFIG" 2>&1); then
    echo "$out" >&2
    die "$CONFIG does not match config.schema.json"
  fi
  ISS_CONFIG_CHECKED=1
}

is_secret() {
  local s
  for s in "${SECRETS[@]}"; do
    [[ $1 == "$s" ]] && return 0
  done
  return 1
}

secret_has_value() {
  local out
  out=$(gcloud secrets versions list "$1" --project "$PROJECT" --filter='state:ENABLED' --limit=1 --format='value(name)') \
    || die "cannot list versions of secret $1 (check gcloud login and access to project $PROJECT)"
  [[ -n $out ]]
}
