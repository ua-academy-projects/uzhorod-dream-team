#!/usr/bin/env bash
set -euo pipefail

COLLECTOR=iss-db
LOG_DIR=/var/log/iss

if [[ -n "${FORCE_COLOR:-}" || ( -t 1 && -z "${NO_COLOR:-}" ) ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi

usage() {
  cat <<EOF
${BOLD}View logs collected on $COLLECTOR${RESET}

${BOLD}Usage:${RESET}
  ./scripts/logs.sh <source> [options]

${BOLD}Sources:${RESET}
  db            postgres, redis, rabbitmq
  history       history service
  fetcher       fetcher service
  ui            nginx
  jump          bastion: SSH logins, fail2ban bans
  collector     log collector journal (what was collected, failures)

${BOLD}Options:${RESET}
  -n N          number of lines (default 100)
  -f            follow new lines (Ctrl+C to stop)
  -s SERVICE    only one service, e.g. postgres, redis, rabbitmq, sshd
  -l LEVEL      error | warn (warn includes errors)
  -g PATTERN    search, case-insensitive regex
  -d DATE       YYYY-MM-DD (default: today, UTC)
  --raw         original log lines, without formatting
  --dates       list dates with logs for the source
  --services    list services in the source's log
  -h, --help    show this help

${BOLD}Examples:${RESET}
  ./scripts/logs.sh history
  ./scripts/logs.sh history -f
  ./scripts/logs.sh db --services
  ./scripts/logs.sh db -s postgres -l warn
  ./scripts/logs.sh fetcher -g "position published" -n 20
  ./scripts/logs.sh jump -g Accepted
  ./scripts/logs.sh ui -d 2026-10-10
EOF
}

die() { printf '%s✖%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

remote() { ssh -o BatchMode=yes "$COLLECTOR" "$@"; }

normalize_source() {
  case $1 in
    db|history|fetcher|ui|jump) echo "iss-$1" ;;
    iss-db|iss-history|iss-fetcher|iss-ui|iss-jump|collector) echo "$1" ;;
    *) die "unknown source '$1' (expected: db history fetcher ui jump collector)" ;;
  esac
}

list_dates() {
  remote "sudo ls $LOG_DIR/$1 2>/dev/null | sed -n 's/\.log\$//p' | sort"
}

list_services() {
  remote "sudo sed -nE -e 's/^([a-z0-9_-]+)-[0-9]+ +\|.*/\1/p' \
    -e 's/^[0-9-]+T[0-9:.]+[+-][0-9]+ [^ ]+ ([a-zA-Z0-9_-]+)[^a-zA-Z0-9_-].*/\1/p' \
    $LOG_DIR/$1/$2.log 2>/dev/null | sort -u"
}

format() {
  awk -v src="$source" -v minlvl="$1" -v rawmode="$2" \
      -v D="$DIM" -v R="$RESET" -v E="$RED" -v G="$GREEN" -v Y="$YELLOW" -v C="$CYAN" '
    function norm(l) {
      l = toupper(l)
      if (l ~ /^(ERR|ERROR|FATAL|PANIC|CRIT|CRITICAL|ALERT|EMERG)$/) return "ERROR"
      if (l ~ /^(WARN|WARNING)$/) return "WARN"
      if (l ~ /^(DEBUG|VERBOSE)$/) return "DEBUG"
      return "INFO"
    }
    function rank(l) { return l == "ERROR" ? 3 : l == "WARN" ? 2 : l == "INFO" ? 1 : 0 }
    {
      sub(/\r$/, "")
      raw = $0
      line = $0
      gsub(/\033\[[0-9;]*m/, "", line)
      svc = src == "collector" ? "collector" : ""
      ts = ""
      lvl = "INFO"

      if (match(line, /^[a-z0-9_-]+-[0-9]+ +\| /)) {
        svc = substr(line, 1, RLENGTH); sub(/-[0-9]+ +\| $/, "", svc)
        line = substr(line, RLENGTH + 1)
      }
      if (match(line, /^[0-9-]+T[0-9:.]+Z /)) {
        ts = substr(line, 12, 8)
        line = substr(line, RLENGTH + 1)
      }

      if (match(line, /^[0-9-]+T[0-9:.]+[+-][0-9]+ [^ ]+ [^ ]+: /)) {
        ts = substr(line, 12, 8)
        split(substr(line, 1, RLENGTH), h, " ")
        svc = h[3]; sub(/[^a-zA-Z0-9_-].*$/, "", svc); sub(/^fail2ban.*/, "fail2ban", svc)
        line = substr(line, RLENGTH + 1)
        if (line ~ /Failed |Invalid user|invalid user|maximum authentication attempts|not allowed because|Connection closed by invalid|\] Ban /) lvl = "WARN"
        if (line ~ /ERROR|error:|fatal:/) lvl = "ERROR"
      } else if (line ~ /^time=[^ ]+ level=[A-Z]+ /) {
        sub(/^time=[^ ]+ /, "", line)
        match(line, /^level=[A-Z]+ /)
        lvl = norm(substr(line, 7, RLENGTH - 7))
        line = substr(line, RLENGTH + 1)
        if (match(line, /^msg="[^"]*"/)) line = substr(line, 6, RLENGTH - 6) substr(line, RLENGTH + 1)
      } else if (match(line, /^[0-9-]+ [0-9:.]+ UTC \[[0-9]+\] [A-Z]+: +/)) {
        hdr = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
        match(hdr, /\] [A-Z]+:/); l = substr(hdr, RSTART + 2, RLENGTH - 3)
        lvl = l ~ /^(LOG|STATEMENT|DETAIL|HINT|CONTEXT)$/ ? "INFO" : norm(l)
      } else if (match(line, /^[0-9-]+ [0-9:.]+\+00:00 \[[a-z]+\] /)) {
        hdr = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
        match(hdr, /\[[a-z]+\]/); lvl = norm(substr(hdr, RSTART + 1, RLENGTH - 2))
        gsub(/<[0-9]+\.[0-9]+\.[0-9]+> ?/, "", line)
      } else if (match(line, /^[0-9]+:[A-Z] [0-9]+ [A-Za-z]+ [0-9]+ [0-9:.]+ [.*#-] /)) {
        c = substr(line, RLENGTH - 1, 1); line = substr(line, RLENGTH + 1)
        lvl = c == "#" ? "WARN" : c == "*" ? "INFO" : "DEBUG"
      } else if (match(line, /^[0-9]+\/[0-9]+\/[0-9]+ [0-9:]+ \[[a-z]+\] [0-9]+#[0-9]+: /)) {
        hdr = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
        match(hdr, /\[[a-z]+\]/); lvl = norm(substr(hdr, RSTART + 1, RLENGTH - 2))
      } else if (match(line, /^[0-9a-fA-F.:]+ - [^ ]+ \[[^]]+\] "[^"]*" [0-9]+ [0-9-]+/)) {
        split(line, q, "\""); split(q[3], s, " "); split(line, f, " ")
        req = q[2]; sub(/ HTTP\/[0-9.]+$/, "", req)
        lvl = s[1] >= 500 ? "ERROR" : s[1] >= 400 ? "WARN" : "INFO"
        line = req " " s[1] " " s[2] "B " f[1]
      } else if (match(line, /^[0-9-]+T[0-9:]+Z /)) {
        ts = substr(line, 12, 8); line = substr(line, RLENGTH + 1)
        if (line ~ / FAILED/) lvl = "ERROR"
      }

      if (rank(lvl) < minlvl) next
      if (rawmode) { print raw; fflush(); next }

      if (length(svc) > 9) svc = substr(svc, 1, 9)
      gsub(/  +/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      tag = lvl == "ERROR" ? E : lvl == "WARN" ? Y : lvl == "DEBUG" ? D : G
      msg = lvl == "ERROR" || lvl == "WARN" ? tag line R : lvl == "DEBUG" ? D line R : line
      printf "%s%-8s%s  %s%-9s%s  %s%-5s%s  %s\n", D, ts, R, C, svc, R, tag, lvl, R, msg
      fflush()
    }'
}

source="" lines=100 follow=0 service="" level="" pattern="" date="" raw=0 show_dates=0 show_services=0

if (( $# == 0 )); then
  usage >&2
  exit 1
fi

while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -n) lines=${2:?-n needs a number}; shift ;;
    -f) follow=1 ;;
    -s) service=${2:?-s needs a service}; shift ;;
    -l) level=${2:?-l needs error or warn}; shift ;;
    -g) pattern=${2:?-g needs a pattern}; shift ;;
    -d) date=${2:?-d needs a date}; shift ;;
    --raw) raw=1 ;;
    --dates) show_dates=1 ;;
    --services) show_services=1 ;;
    -*) die "unknown option '$1' (see -h)" ;;
    *) [[ -z $source ]] || die "only one source allowed"; source=$(normalize_source "$1") ;;
  esac
  shift
done
[[ -n $source ]] || die "no source given (see -h)"

if (( show_dates )); then
  list_dates "$source"
  exit 0
fi

date=${date:-$(date -u +%F)}
[[ $lines =~ ^[0-9]+$ ]]                || die "-n must be a number"
[[ $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "-d must be YYYY-MM-DD"

if (( show_services )); then
  list_services "$source" "$date"
  exit 0
fi
[[ -z $service || $service =~ ^[a-z0-9_-]+$ ]] || die "invalid service name '$service'"

case $level in
  "")    minlvl=0 ;;
  warn)  minlvl=2 ;;
  error) minlvl=3 ;;
  *)     die "-l must be error or warn" ;;
esac

file="$LOG_DIR/$source/$date.log"
grep_opts=""
(( follow )) && grep_opts="--line-buffered"

filters=""
[[ -n $service ]] && filters+=" | grep $grep_opts -E $(printf %q "^${service}-[0-9]+ +\\| |^[0-9-]+T[^ ]+ [^ ]+ ${service}[^a-zA-Z0-9_-]")"
[[ -n $pattern ]] && filters+=" | grep $grep_opts -iE -- $(printf %q "$pattern")"

check="sudo test -f $(printf %q "$file") || { echo 'no logs for $source on $date (try --dates)' >&2; exit 3; }"
if (( follow )); then
  stream="sudo tail -n $lines -F $(printf %q "$file") $filters"
  if [[ -t 0 ]]; then
    cmd="$check; trap 'kill 0' EXIT; $stream & cat >/dev/null"
  else
    cmd="$check; $stream"
  fi
elif [[ -n $level ]]; then
  cmd="$check; sudo cat $(printf %q "$file") $filters"
else
  cmd="$check; sudo cat $(printf %q "$file") $filters | tail -n $lines"
fi

summary="$source · $date"
[[ -n $service ]] && summary+=" · service=$service"
[[ -n $level ]]   && summary+=" · level=$level"
[[ -n $pattern ]] && summary+=" · search=\"$pattern\""
(( follow )) && summary+=" · following (Ctrl+C to stop)" || summary+=" · last $lines lines"
printf '%s==>%s %s%s%s\n' "$CYAN$BOLD" "$RESET" "$BOLD" "$summary" "$RESET"

if (( follow )); then
  remote "$cmd" | format "$minlvl" "$raw" || true
elif [[ -t 1 ]]; then
  remote "$cmd" | format "$minlvl" "$raw" | tail -n "$lines" | less -RFX
else
  remote "$cmd" | format "$minlvl" "$raw" | tail -n "$lines"
fi
