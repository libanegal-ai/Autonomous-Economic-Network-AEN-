# AEN Testnet — VPS Deployment Guide

Axis Ledger Lab Ltd · AEN Core Testnet · V4.0 Launch Package (Full-Stack App)

## Sequence

Run these **in order**, on each VPS that will run a validator:

| Step | Script | Purpose |
|---|---|---|
| 1 | `01_provision_vps.sh` | Hardens the box (ufw, fail2ban), creates the `aen` service user, installs Nginx, Certbot, Rust, Node.js, Docker |
| — | `node/` (build) | Compile the AEN core node — see below |
| 2 | `03_deploy_node.sh <binary> <node.toml>` | Installs the compiled `aen-node` Rust binary as a systemd service |
| 3 | `05_deploy_gateway.sh <gateway-dir>` | Installs the Node.js API Gateway, which proxies the live node RPC as public REST, bound to `aen-node` |
| 4 | `02_deploy_dashboard.sh <domain> <gateway/public/index.html> [email]` | Publishes the **live** dashboard behind Nginx + TLS. Nginx's `/api/` block already points at the gateway on `127.0.0.1:8080` |
| 5 | `04_p2p_smoke_test.sh <peer-ip>` | **Critical gate.** Confirms peering, gossip, and block-height liveness between nodes |

Minimum viable full-stack testnet = **2 VPS instances**, each running steps
1–4 in order, then step 5 run from each pointing at the other.

**Important:** at step 4, point the script at `gateway/public/index.html`,
not the older standalone `aen-testnet-v3.html` in the repo root. The
gateway's copy polls `/api/explorer/summary` every 5 seconds and shows real
block height / peer count / uptime in a "Live Core Network" card at the
top of the Explorer tab — everything else on the dashboard (agents,
marketplace, wallet, x402 demo) is still the original simulation and is
now labeled `(sim)` in the UI so it's never mistaken for live chain data.

## Building the AEN core node (`node/`)

The `node/` folder contains the full Rust source for `aen-node` — a
verified, working RPC + P2P testnet node. This exact build was compiled
and test-run locally (two nodes peered, exchanged handshakes, and
finalized blocks on schedule) and it passed `04_p2p_smoke_test.sh`
end-to-end before being included here.

```
cd node/
cargo build --release
# binary is now at target/release/aen-node
```

Copy `config/node.toml.example` to `node.toml`, set a unique `node_id`
per machine, and for every node after the first, add the previous node's
`<public-ip>:30333` to `bootnodes`. Feed that binary and config into
`03_deploy_node.sh`.

What it does today: RPC (`/health`, `/peers`, `/status`, `/metrics`),
raw-TCP P2P with a signed (ed25519) handshake + keepalive gossip, a
timer-driven block-production loop gated on peer count (stands in for the
real Proof of Intelligence consensus logic, still under active
development), and file-based persistence so block height and node identity
survive restarts.

Each node keeps two files under `--data-dir` (default `./data`):
`identity.key` (its ed25519 private key — treat like any other secret) and
`state.json` (current block height).

## The API Gateway (`gateway/`)

`gateway/` is a small Node.js/Express service that is the **only** thing
allowed to talk to a node's RPC (which stays bound to 127.0.0.1). It was
built and verified locally end-to-end: with a live node running, the
gateway correctly proxied `/health`, `/status`, and `/peers`, and its
`/api/explorer/summary` endpoint showed block height advancing in
real time as the underlying node produced blocks.

Endpoints:
- `GET /api/health` — gateway + upstream node health
- `GET /api/network/status` — live block height, uptime, peer count
- `GET /api/network/peers` — live peer list
- `GET /api/explorer/summary` — combined view the dashboard polls

`gateway/public/index.html` is the dashboard, served directly by the
gateway for local testing and copied to Nginx's web root in production
(step 4).

## Why the P2P gate matters

Backend services should not be trusted for real users until step 5
passes cleanly on at least two independently hosted nodes. Treat a
`FAIL` from `04_p2p_smoke_test.sh` as a blocker, not a warning.

## Ports

| Port | Purpose | Exposure |
|---|---|---|
| 22 | SSH | Public (lock down with key-only auth + fail2ban) |
| 80 / 443 | Dashboard + `/api/` (Nginx + TLS) | Public |
| 30333 | P2P gossip (`aen-node`) | Public — required for validators to find each other |
| 9944 | Local RPC (`aen-node`) | **Not public.** Bound to 127.0.0.1; only the gateway talks to it |
| 8080 | API Gateway | **Not public directly.** Bound to 127.0.0.1; reached only via Nginx `/api/` |

## Rollback / troubleshooting

- Node won't start: `journalctl -u aen-node -f`
- Gateway won't start / 502 on `/api/`: `journalctl -u aen-gateway -f`, confirm `aen-node` is up first (gateway is `BindsTo=aen-node.service`)
- No peers: check `ufw status`, confirm port 30333 open on **both** sides, confirm bootnode address in `node.toml`
- Dashboard 502/504: `nginx -t`, `systemctl status nginx`, confirm `/var/www/aen-testnet/index.html` exists
- Cert renewal: handled automatically by `certbot.timer` — verify with `systemctl list-timers | grep certbot`

## Assessment fixes applied (2026-07-15)

Following `AEN_Technical_Assessment.pdf`, the following changes went into
this package. All are in `node/src/main.rs` unless noted:

1. **Block-gate bug fixed.** The block-production loop had `if
   !s.peers.is_empty() || true`, which always produced blocks regardless of
   peer count. Removed `|| true` so blocks only advance once ≥1 peer is
   connected — this matches both the original doc comment and what
   `04_p2p_smoke_test.sh` checks for.
2. **CLI now accepts what systemd was already passing.** `--data-dir`,
   `--rpc-bind`, `--p2p-bind`, and `--log-dir` are real, parsed flags (via
   `clap`) that do something, instead of being silently ignored.
3. **Persistence added.** `block_height` is written to
   `<data-dir>/state.json` after every block and restored on startup —
   restarts no longer reset height to 0. (Deliberately simple file-based
   persistence rather than sled/sqlite, to keep the binary dependency-light;
   revisit if/when real chain state needs indexed storage.)
4. **Peer-key format unified.** Both inbound and outbound peers are now
   tracked as `"{node_id}@{addr}"`, so `/peers` no longer mixes two
   incompatible formats depending on connection direction.
5. **Monitoring stack added.** `monitoring/docker-compose.yml` +
   `monitoring/prometheus.yml` — previously referenced in step 1 but never
   shipped. The node now also exposes `GET /metrics` in Prometheus text
   format (block height, peer count, uptime).
6. **Signed handshake.** Each node now has a persistent ed25519 identity
   (`<data-dir>/identity.key`, generated on first run). HELLO messages are
   signed and verified before a peer is trusted, closing the "anyone can
   claim any node_id" spoofing gap. This does not by itself prevent Sybil
   attacks (a new identity is still free to mint) — that needs a
   staking/whitelist layer, out of scope here.
7. **Housekeeping.** Removed unused `hashbrown`/`indexmap` dependencies from
   `Cargo.toml`; fixed the stale "unused until built" Nginx comment in
   `02_deploy_dashboard.sh` to reflect the actual deploy order.

**Before building:** `Cargo.toml` gained new dependencies (`clap`,
`ed25519-dalek`, `rand`, `hex`) and the old `Cargo.lock` was removed since
it no longer matches. Run `cargo build --release` on a machine with
internet access (as the guide already assumes) — Cargo will regenerate the
lockfile automatically.

**Not yet addressed** (flagged in the assessment but out of scope for this
pass): real PoI consensus (still a timer stub), gateway-side auth/CORS
hardening, and full Sybil resistance for P2P identity.

## Second assessment pass — hardening fixes (2026-07-19)

Following a deeper review of the 2026-07-15 package, these additional fixes
went in. All are in `node/src/main.rs` unless noted.

1. **identity.key permissions.** The old code wrote the private ed25519 key
   with a comment claiming "0600-equivalent" but never actually set the
   mode, so under a default umask (022) the file was world-readable.
   `identity.key` is now explicitly chmod'd 0600 on creation, and this is
   re-asserted on every startup (self-healing an existing file from a
   pre-fix install).
2. **Handshake is now bound to the TCP session.** Previously a HELLO's
   signature covered only `node_id|pubkey|ts` — nothing tied it to a
   specific connection, so a HELLO captured within the 60s replay window
   could in principle be replayed onto a different connection. Both sides
   now exchange a random nonce (`NONCE <hex>`) before sending HELLO, and
   sign over the *peer's* nonce, so a captured HELLO only verifies on the
   exact connection it was produced for. Wire format is now
   `HELLO <node_id> <pubkey_hex> <ts> <peer_nonce> <sig_hex>`.
3. **Inbound P2P connections are now capped.** The listener previously
   spawned a task for every accepted TCP connection with no limit, before
   the handshake was even checked — a trivial flood could exhaust file
   descriptors/tasks. A new `max_inbound_peers` config option (default 256)
   gates this via a semaphore; connections beyond the cap are dropped
   immediately instead of spawned.
4. **state.json is now signed.** `block_height` is signed with the node's
   own identity key on save and verified on load; an unsigned or
   tampered file is rejected (falls back to height 0 with a logged
   warning) instead of being trusted silently. Files written by a
   pre-fix build have no `sig` field and will trigger this fallback once
   on upgrade — expected, not a bug.
5. **Nginx: added a rate-limit zone and HSTS.** `02_deploy_dashboard.sh`
   now defines `limit_req_zone` (60 req/min/IP, burst 20) in front of the
   `/api/` proxy — this stops a flood before it reaches the gateway process
   at all, on top of the gateway's own 120/min express-rate-limit. Also
   added a `Strict-Transport-Security` header.

**Not addressed in this pass (unchanged from before):** real PoI consensus,
Sybil resistance (still requires a staking/whitelist layer), and gateway-side
auth — the gateway's endpoints remain deliberately open/read-only for a
public testnet explorer, which is a design choice worth stating explicitly
rather than an oversight.

**Compile note:** this pass was verified by careful manual review, not a
full `cargo build`, because the review sandbox's system Rust (apt-provided,
1.75.0) is too old to resolve current crates.io versions of some transitive
dependencies (they now require `edition2024`) — this is a pre-existing
sandbox limitation, not something introduced by these changes, and does not
affect building on a real machine via `rustup` as the guide already assumes.
Run `cargo build --release` as your first verification step.

## Next steps after a passing P2P smoke test

1. Onboard additional validators (repeat steps 1–5 per node)
2. Add real endpoints to the gateway as each subsystem goes from simulation to live (agents/identity, wallet, marketplace, x402)
3. Point Faucet/SDK/Developer Portal at the API Gateway, never directly at node RPC
4. Bring up monitoring: `cd monitoring/ && docker compose up -d` — Prometheus scrapes `aen-node`'s new `/metrics` endpoint on 127.0.0.1:9944 (Docker/Compose was already installed in step 1)
5. Replace the timer-driven block-production stub with the real PoI consensus module once it's ready
