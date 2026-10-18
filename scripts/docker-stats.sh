#!/usr/bin/env bash
set -euo pipefail

VMS=(iss-db iss-history iss-fetcher iss-ui)

export LC_ALL=C.UTF-8

if [[ -n "${FORCE_COLOR:-}" || ( -t 1 && -z "${NO_COLOR:-}" ) ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi

REMOTE=$(cat <<'EOF'
sudo docker ps -a --format 'PS\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}'
sudo docker stats --no-stream --format 'ST\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}'
sudo docker images --format 'IMG\t{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'
sudo docker system df --format 'DF\t{{.Type}}\t{{.Size}}\t{{.Reclaimable}}'
awk '/^MemTotal/ {t = $2} /^MemAvailable/ {a = $2} END {printf "MEM\t%d\t%d\n", (t - a) * 1024, t * 1024}' /proc/meminfo
df -B1 --output=used,size / | awk 'NR == 2 {printf "DISK\t%s\t%s\n", $1, $2}'
printf 'SYS\t%s\t%s\n' "$(cut -d' ' -f1 /proc/loadavg)" "$(uptime -p | sed 's/^up //')"
EOF
)

section() { printf '\n%s%s%s\n' "$BOLD$CYAN" "$*" "$RESET"; }

table() {
  awk -F'\t' -v B="$BOLD" -v D="$DIM" -v R="$RESET" -v G="$GREEN" -v Y="$YELLOW" -v E="$RED" '
    function paint(s,   p) {
      if (s ~ /[█░]/ && match(s, /[0-9]+%/)) {
        p = substr(s, RSTART, RLENGTH - 1) + 0
        return (p >= 90 ? E : p >= 70 ? Y : G) s R
      }
      if (s ~ /(exited|dead|unhealthy|offline)/)  return E s R
      if (s ~ /(restarting|starting|paused|created)/) return Y s R
      if (s ~ /^(running|Up )/)                   return G s R
      return s
    }
    {
      for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
      if (NF > nf) nf = NF
    }
    END {
      if (NR <= 1) { print "  " D "(none)" R; exit }
      for (r = 1; r <= NR; r++) {
        line = "  "
        for (i = 1; i <= nf; i++) {
          s = cell[r, i]
          line = line (r == 1 ? B s R : paint(s))
          if (i < nf) line = line sprintf("%" (w[i] - length(s) + 3) "s", "")
        }
        print line
        if (r == 1) {
          sep = "  "
          for (i = 1; i <= nf; i++) {
            for (k = 0; k < w[i]; k++) sep = sep "─"
            if (i < nf) sep = sep "   "
          }
          print D sep R
        }
      }
    }'
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
start=$SECONDS

printf '%s==>%s %sCollecting Docker stats from %d VMs%s\n' "$CYAN$BOLD" "$RESET" "$BOLD" "${#VMS[@]}" "$RESET"
for vm in "${VMS[@]}"; do
  (ssh -o BatchMode=yes -o ConnectTimeout=5 "$vm" 'bash -s' <<<"$REMOTE" >"$TMP/$vm" 2>/dev/null \
    || echo OFFLINE >"$TMP/$vm") &
done
wait

section "Virtual machines"
{
  printf 'VM\tADDRESS\tSTATE\tLOAD\tUPTIME\tMEMORY\tDISK\tCONTAINERS\n'
  for vm in "${VMS[@]}"; do
    ip=$(ssh -G "$vm" | awk '$1 == "hostname" {print $2}')
    awk -F'\t' -v vm="$vm" -v ip="$ip" '
      function hum(b) { return b >= 1073741824 ? sprintf("%.1fG", b / 1073741824) : sprintf("%.0fM", b / 1048576) }
      function bar(u, t,   p, f, s, i) {
        p = t > 0 ? int(100 * u / t + 0.5) : 0
        f = int(p / 10 + 0.5); s = ""
        for (i = 0; i < 10; i++) s = s (i < f ? "█" : "░")
        return s sprintf(" %3d%% ", p) hum(u) "/" hum(t)
      }
      $1 == "OFFLINE" { off = 1 }
      $1 == "MEM"     { mem = bar($2, $3) }
      $1 == "DISK"    { disk = bar($2, $3) }
      $1 == "SYS"     { load = $2; up = $3 }
      $1 == "PS"      { total++; if ($4 == "running") run++ }
      END {
        if (off) { printf "%s\t%s\toffline\t-\t-\t-\t-\t-\n", vm, ip; exit }
        printf "%s\t%s\trunning\t%s\t%s\t%s\t%s\t%d/%d running\n", vm, ip, load, up, mem, disk, run, total
      }' "$TMP/$vm"
  done
} | table

section "Containers"
{
  printf 'VM\tCONTAINER\tIMAGE\tSTATE\tSTATUS\tCPU\tMEMORY\tNET I/O\n'
  for vm in "${VMS[@]}"; do
    awk -F'\t' -v vm="$vm" '
      $1 == "PS" { n++; name[n] = $2; img[n] = $3; st[n] = $4; status[n] = $5 }
      $1 == "ST" { cpu[$2] = $3; split($4, m, " / "); mem[$2] = m[1]; net[$2] = $5 }
      END {
        for (i = 1; i <= n; i++) {
          c = name[i]
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", vm, c, img[i], st[i], status[i],
            (c in cpu ? cpu[c] : "-"), (c in mem ? mem[c] : "-"), (c in net ? net[c] : "-")
        }
      }' "$TMP/$vm"
  done
} | table

section "Images"
{
  printf 'VM\tIMAGE\tSIZE\tCREATED\n'
  for vm in "${VMS[@]}"; do
    awk -F'\t' -v vm="$vm" '$1 == "IMG" { printf "%s\t%s\t%s\t%s\n", vm, $2, $3, $4 }' "$TMP/$vm"
  done
} | table

section "Docker disk usage"
{
  printf 'VM\tIMAGES\tCONTAINERS\tVOLUMES\tBUILD CACHE\tCACHE RECLAIMABLE\n'
  for vm in "${VMS[@]}"; do
    awk -F'\t' -v vm="$vm" '
      $1 == "OFFLINE" { off = 1 }
      $1 == "DF"      { size[$2] = $3; rec[$2] = $4 }
      END {
        if (off) exit
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", vm, size["Images"], size["Containers"], size["Local Volumes"],
          size["Build Cache"], rec["Build Cache"]
      }' "$TMP/$vm"
  done
} | table

printf '\n  %scollected in %ds%s\n' "$DIM" "$((SECONDS - start))" "$RESET"
