#!/bin/sh
set -eu

host=$1
mkdir /t
cp -a /le/. /t/
cd /t

for d in live/* archive/*; do
  [ -e "$d" ] || continue
  [ "$(basename "$d")" = "$host" ] || rm -rf "$d"
done
for f in renewal/*.conf; do
  [ -e "$f" ] || continue
  [ "$f" = "renewal/$host.conf" ] || rm -f "$f"
done
if [ -d "archive/$host" ]; then
  for f in "archive/$host"/*; do
    keep=0
    for l in "live/$host"/*.pem; do
      [ "$(readlink -f "$l")" = "$(readlink -f "$f")" ] && keep=1
    done
    [ "$keep" = 1 ] || rm -f "$f"
  done
fi
find . | while read -r p; do touch -h -r "/le/$p" "$p"; done

tar cf - . | gzip -n | base64 -w0
