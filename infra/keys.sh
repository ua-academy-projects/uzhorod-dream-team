#!/usr/bin/env bash
set -euo pipefail

gcloud compute os-login ssh-keys add \
   --key-file=/home/ian/.ssh/id_ed25519.pub \
   --project=uzhorodosmproject \
   --ttl=30