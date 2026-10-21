#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

vagrant up
deploy/build.sh
deploy/frontend.sh
deploy/set-queue.sh
