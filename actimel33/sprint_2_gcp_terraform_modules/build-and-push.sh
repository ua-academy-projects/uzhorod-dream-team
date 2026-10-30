#!/bin/bash
# Builds the db, history, fetcher and ui images and pushes them to Artifact Registry
# with the tags from config.json.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG=$DIR/../terraform_resources_configuration/config.json

# config_value KEY [KEY...] prints the value of config.json at that path.
config_value() {
  python3 -I -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value[key]
print(value)' "$CONFIG" "$@"
}

PROJECT=$(config_value project id)
REGION=$(config_value project region)
REPOSITORY=$(config_value registry repository_id)
REGISTRY=$REGION-docker.pkg.dev/$PROJECT/$REPOSITORY

# push_image NAME CONTEXT [DOCKERFILE]
push_image() {
  local name=$1
  local context=$2
  local dockerfile=${3:-$2/Dockerfile}
  local image
  image=$REGISTRY/$name:$(config_value vms machines "$name" image_tag)

  if gcloud artifacts docker images describe "$image" >/dev/null 2>&1; then
    echo "skip $image: already in the registry"
    return
  fi
  echo "==> $image"
  docker build -t "$image" -f "$dockerfile" "$context"
  docker push "$image"
}

gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

push_image db "$DIR/db"
push_image history "$DIR" "$DIR/services/history/Dockerfile"
push_image fetcher "$DIR/services/fetcher"
push_image ui "$DIR/ui"
