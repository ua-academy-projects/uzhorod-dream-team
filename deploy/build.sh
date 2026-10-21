#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
T=x86_64-unknown-linux-musl

cargo build --release --target $T --manifest-path fetcher/Cargo.toml
cargo build --release --target $T --manifest-path history/Cargo.toml

push() { # <name>: binary, service and VM share one name
  vagrant upload "$1/target/$T/release/$1" /tmp/$1 "$1"
  vagrant ssh "$1" -c "sudo install -m755 /tmp/$1 /usr/local/bin/$1 && { [ ! -f /etc/queue.env ] || sudo systemctl restart $1; }"
}
push fetcher
push history
