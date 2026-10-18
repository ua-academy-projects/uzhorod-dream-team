# Architecture

## Overview

```
  Wi-Fi: phone, other laptops
            │ <laptop IP>:5173 (UI)                │ <laptop IP>:2222 (ssh)
            ▼                                      ▼
  Windows: netsh portproxy · route 192.168.78.0/24 via WSL
            │                                      │
 ═══════════╪══ WSL · Vagrant + libvirt/KVM ═══════╪════════════════════════════
            │  edge 192.168.78.0/24 · DMZ          │
            ▼                                      ▼
  ┌───────────────────┐                  ┌───────────────────┐
  │ ui         .78.13 │                  │ bastion     .78.5 │
  │ nginx      :5173  │                  │ sshd only: user   │
  │ React build       │                  │ jump forwards to  │
  └─────────┬─────────┘                  │ :22, no shell     │
            │ /api/*                     └─────────┬─────────┘
  ──────────┼─ private 192.168.77.0/24 · isolated ─┴─ ssh to :22 of every VM ─
            ▼
  ┌───────────────────┐       queue      ┌───────────────────┐  HTTPS
  │ history    .77.12 │◀ ─ ─ ─ ─ ─ ─ ─ ─▶│ fetcher    .77.11 │─────────▶ CoinGecko
  │ node       :3001  │    (on db)       │ go :3002 /health  │
  └─────────┬─────────┘                  └─────────┬─────────┘
            │ SQL · queue · sessions               │ queue
            ▼                                      ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ db                                                   .77.10 │
  │ crypto_db     postgres 17 + pgmq   :5432   always           │
  │ crypto_redis  redis 7              :6379   BACKEND=redis    │
  │ /srv/logs     container logs of every VM                    │
  └─────────────────────────────────────────────────────────────┘

  every service: one Docker container on its own VM
  internet for apt / docker / CoinGecko: Vagrant management network 192.168.121.0/24
```

- history and fetcher never call each other — only through the queue;
- only history writes prices; the fetcher's HTTP is `/health` only;
- from outside only the UI and the bastion are reachable: [NETWORK-ACCESS.md](NETWORK-ACCESS.md).

## Networks

```
 Windows / Wi-Fi
       │  a route exists only to this network
       ▼
 crypto-edge     192.168.78.0/24 ── ordinary libvirt network, reachable from outside
       │                │
    bastion            ui            ← the only VMs with a second interface (edge_ip)
       │                │
 crypto-private  192.168.77.0/24 ── isolated: forward_mode none, no route in or out
       │         │          │          │          │
    bastion      db      fetcher    history      ui

 Vagrant management 192.168.121.0/24 (added by Vagrant): provisioning, internet for the VMs
```

- **private** — every VM; services talk here (history → db, fetcher → db, ui → history).
- **edge** — only the bastion (admins come in) and ui (users come in): a DMZ, like a public subnet.
- One network would not do: a route from Windows to the UI would expose db, history and fetcher too.
- `private_network` is just Vagrant's name for a host-only network; `forward_mode: "none"` is what makes
  `crypto-private` isolated, so the VMs reach the internet through the management network.

## BACKEND

| | `redis` (default) | `postgres` |
|---|---|---|
| queue | Redis Streams | pgmq extension |
| sessions (key-value) | Redis keys with TTL | **hstore** extension: table `session` |
| Redis container | yes | no |

```
BACKEND=postgres vagrant provision db fetcher history     # remembered in .vagrant/backend
```

Both implementations are in the same images; the flag picks one when the container starts.
`/health` of history and fetcher shows which one runs.

## Data flow

```
 page load     browser ─▶ nginx ─▶ history ─▶ postgres: newest point
                 fresh (< 15 min)  → 200
                 stale             → 200 stale + request queued, UI rechecks every 4 s
                 nothing stored    → 503 + request queued

 refresh       browser ─POST /api/refresh─▶ history ─request─▶ queue ─▶ fetcher ─▶ CoinGecko
               browser ◀── 202 ──────────── history
                                            history ◀─result── queue ◀─ fetcher
                                            history ─INSERT─▶ postgres
               UI re-reads after 2.5 s

 bootstrap     history start, empty table → request { days: 7 } → ~169 hourly points
 timer         fetcher every 12 h → result with origin "timer"
```

Duplicates: `UNIQUE (coin, vs_currency, observed_at)` + `ON CONFLICT DO NOTHING`.
Unknown `coin`/`vs` → 404, no CoinGecko call.

## Queue

```
 sender ─send─▶ queue ─read─▶ receiver      message leased for 30 s
                               ├─ done          → ack, removed
                               ├─ crash / error → no ack, back after 30 s
                               └─ malformed/4xx → ack, dropped
```

| | Redis Streams | pgmq |
|---|---|---|
| read | `XREADGROUP BLOCK 5 s` | `read_with_poll`, 5 s |
| ack | `XACK` | `pgmq.delete` |
| retry | `XAUTOCLAIM` after 30 s | visibility timeout 30 s |
| dedup | `SET pending:<pair> NX EX 30` | unique index on waiting requests |

The fetcher logs into Postgres as `queue_worker`: requests and results only.

## Session

```
 browser ──cookie connect.sid (signed id)──▶ history ──▶ redis | table "session" (hstore)
 value: { theme: light | dark | system } · 30 days
```

With `BACKEND=postgres` a session is a row of key-value pairs (`005_session_hstore.sql`,
store: `http/pg-session-store.ts`):

```
 sid      | data (hstore)                                  | expire
 aB3x…    | "theme"=>"dark", "cookie"=>"{maxAge, expires…}" | +30 days
```

Expired rows are never served and are deleted every 15 min; `select data->'theme' from session`.

## Provisioning

```
 host: vagrant up ─▶ .vagrant/  secrets · backend · per-VM env · keys · ssh config · payload
        │
        │ 5 VMs in parallel
  ┌─────┴──────┬─────────────────┬────────────────┬────────────────┐
  bastion      db                fetcher          history          ui
  user jump    pgmq image        wait db          wait db          build, run
  sshd: keys   crypto_db         build, run       build, run       wait history
  only         (+ crypto_redis)                                    e2e /api/health
               logs collector
               └── these four: logship cron · ssh-guard (sshd + nftables)
```

- each container gets only its variables, from a 0600 env file — no secret on a command line;
- images are built on each VM; no registry, no compose.

## Containers

| container | runtime image | size | runs with |
|---|---|---|---|
| `crypto_ui` | nginx-unprivileged | ~82 MB | `-p 5173:8080` |
| `crypto_history` | distroless/nodejs24 | ~227 MB | `--read-only --init` |
| `crypto_fetcher` | distroless/static | ~19 MB | `--read-only` |
| `crypto_db` | postgres:17-alpine + pgmq | | volume `pgdata` |
| `crypto_redis` | redis:7-alpine | | volume `redisdata` |

All: multi-stage builds, non-root, `HEALTHCHECK`, `--restart unless-stopped`.

## SSH

```
 host: ssh db ─▶ bastion (user jump: TCP forward to :22 only) ─▶ db:22
                 the key is checked by db; the bastion sees only encrypted traffic

 bastion   ssh bastion → no shell, no terminal; LogLevel VERBOSE (who, which key)
 every VM  :22 only from the bastion and Vagrant — sshd AllowUsers + nftables
```

One project key `.vagrant/bastion/id_ed25519` (generated, git-ignored);
`.vagrant/ssh/config` sets `ProxyJump bastion`, so `ssh db` just works.

## Logs

```
 every VM, cron */15                                    db
 docker logs ─▶ /var/spool/logship ──ssh logs@db──▶ logsink ─▶ /srv/logs/<vm>/<container>.log
                (deleted after success)
```

The `logs` key per VM: `restrict` (no shell), `from=<VM IP>`, `command=logsink <vm>` —
it can only append to that VM's directory. Kept 7 days on db, 3 × 10 MB per container on a VM.

## Limits

- logs arrive up to 15 min late;
- switching `BACKEND` drops waiting messages and sessions;
- host key checks are off for ssh between machines: VMs are recreated;
- one instance per service.
