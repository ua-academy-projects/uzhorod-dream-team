#!/usr/bin/env bash
# Upload the prebuilt binaries and the frontend files to gs://<project>-artifacts, where the ian.main roles pull them from.
# Builds nothing. Usage: ./upload-artifacts.sh [fetcher|history|frontend|all]   (default: all)
#
# Writing to the bucket needs storage.admin, so when terraform.env is sourced
# (GOOGLE_IMPERSONATE_SERVICE_ACCOUNT) the upload runs as the terraform service account.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

APPS=../apps
TARGET=x86_64-unknown-linux-musl # static: independent of the glibc of the VMs

die() { echo "error: $*" >&2; exit 1; }

command -v gcloud >/dev/null || die "gcloud is not installed"
PROJECT_ID=$(python3 -c 'import json; print(json.load(open("config.json"))["project_id"])') ||
  die "could not read project_id from config.json"
BUCKET="gs://${PROJECT_ID}-artifacts"

GC=(gcloud storage)
if [ -n "${GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:-}" ]; then
  export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$GOOGLE_IMPERSONATE_SERVICE_ACCOUNT"
fi

"${GC[@]}" buckets describe "$BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1 ||
  die "$BUCKET not found: run terraform apply first (modules/iam creates it)"

upload_binary() { # <name>
  local name=$1 src="$APPS/$1/target/$TARGET/release/$1"
  [ -f "$src" ] || die "$src is missing; build it first:
    rustup target add $TARGET
    cargo build --release --target $TARGET --manifest-path $APPS/$name/Cargo.toml"
  echo "==> $name -> $BUCKET/$name/$name"
  "${GC[@]}" cp "$src" "$BUCKET/$name/$name"
  printf '    %s bytes, sha256 %s\n' "$(stat -c %s "$src")" "$(sha256sum "$src" | cut -d' ' -f1)"
}

upload_frontend() {
  local src="$APPS/frontend"
  [ -f "$src/index.html" ] || die "$src/index.html is missing"
  echo "==> frontend -> $BUCKET/frontend/"
  "${GC[@]}" rsync -r --delete-unmatched-destination-objects "$src" "$BUCKET/frontend"
  (cd "$src" && sha256sum -- *) | sed 's/^/    /'
}

case "${1:-all}" in
fetcher) upload_binary fetcher ;;
history) upload_binary history ;;
frontend) upload_frontend ;;
all)
  upload_binary fetcher
  upload_binary history
  upload_frontend
  ;;
*) die "usage: $0 [fetcher|history|frontend|all]" ;;
esac
