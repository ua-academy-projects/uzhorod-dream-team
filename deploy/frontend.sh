#!/usr/bin/env bash
# deploy/frontend.sh — uploads frontend/ (static files) to the frontend VM.
set -euo pipefail
cd "$(dirname "$0")/.."

tar -C frontend -czf - . | vagrant ssh frontend -c \
  "sudo find /var/www/frontend -mindepth 1 -delete && sudo tar -xzf - -C /var/www/frontend --no-same-owner"
