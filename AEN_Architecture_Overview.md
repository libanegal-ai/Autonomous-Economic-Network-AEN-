# AEN (Agent Economic Network) — Architecture Overview

**Axis Ledger Lab Ltd** · AEN Core Testnet · V4.0

## 1. What AEN is

AEN is a blockchain-based settlement and identity layer for autonomous AI
agents transacting economic value with each other and with humans. This
repository contains the **core testnet**: a working node, P2P network,
public API gateway, and explorer dashboard — the infrastructure layer the
rest of AEN (agent identity, marketplace, wallet, x402 payment flow) is
built on top of.

This document describes what is real and running today versus what is
still a labeled simulation, so a reviewer can see exactly where the system
stands.

## 2. System diagram

```
                        ┌─────────────────────────┐
                        │   Browser (Explorer)    │
                        └───────────┬─────────────┘
                                    │ HTTPS
                        ┌───────────▼─────────────┐
                        │  Nginx (TLS, rate-limit) │
                        └───────┬───────────┬──────┘
                       static   │           │ /api/*
                       assets   │           │
                        ┌───────▼───┐  ┌────▼──────────────┐
                        │ index.html│  │  API Gateway (Node)│
                        └───────────┘  │  server.js :8080   │
                                       └────────┬───────────┘
                                                │ 127.0.0.1:9944 only
                                       ┌────────▼───────────┐
                                       │   aen-node (Rust)   │
                                       │  RPC + P2P + PoI    │
                                       └────────┬───────────┘
                                                │ TCP :30333, signed gossip
                                       ┌────────▼───────────┐
                                       │   Peer aen-node(s)  │
                                       │  (other validators) │
                                       └─────────────────────┘
```

Each validator VPS runs one `aen-node` + one API Gateway. The gateway is
the **only** process allowed to reach the node's RPC (bound to
`127.0.0.1:9944`); the node's P2P port (`30333`) is the only thing exposed
between validators.

## 3. Components

### 3.1 Core node (`node/`, Rust)
- **RPC** (axum): `/health`, `/peers`, `/status`, `/metrics` (Prometheus).
- **P2P** (raw TCP, ed25519-signed, nonce-bound handshake): peer discovery
  via configured bootnodes, keepalive gossip, replay-resistant HELLO
  exchange.
- **Consensus (PoI — Proof of Intelligence): stub.** Block height advances
  on a fixed timer once ≥1 peer is connected. This is a liveness
  placeholder, not the real scoring/selection algorithm — the real PoI
  module (agent-quality-weighted validator selection) is still under
  active design and is the single biggest piece of unbuilt work in the
  system.
- **Persistence:** `state.json` (signed block height) and `identity.key`
  (ed25519 private key, 0600 permissions) survive restarts.

### 3.2 API Gateway (`gateway/`, Node.js/Express)
Public REST layer in front of the node RPC. Read-only, deliberately open
(no auth) since it serves public network-status data for the explorer —
the same design used by every public blockchain explorer API. Adds its
own rate limiting on top of Nginx's.

### 3.3 Dashboard (`gateway/public/index.html`)
Single-page explorer. The "Live Core Network" card polls
`/api/explorer/summary` every 5s and shows real block height / peer count /
uptime. Everything else on the page (agent marketplace, wallet, x402 demo)
is explicitly labeled **(sim)** — in-memory simulation data, not yet backed
by chain state. This labeling is intentional: nothing on the dashboard
claims to be live unless it is.

### 3.4 Monitoring (`monitoring/`)
Prometheus scrapes `aen-node`'s `/metrics` endpoint. Grafana can be layered
on top (not included yet).

## 4. Security model — current state

| Property | Status |
|---|---|
| Peer identity spoofing | Prevented — signed, nonce-bound handshake |
| Handshake replay across connections | Prevented — signature bound to per-connection nonce |
| Private key exposure on disk | Mitigated — `identity.key` enforced to 0600 |
| State tampering (`state.json`) | Detected — signed, verified on load |
| Inbound connection flood | Bounded — capped concurrent P2P connections |
| API abuse / request flood | Rate-limited at both Nginx and gateway layers |
| **Sybil resistance** | **Not yet implemented** — anyone can mint a new identity; needs a staking/whitelist layer |
| **Real PoI consensus** | **Not yet implemented** — currently a timer stub gated on peer count |
| Gateway authentication | Intentionally absent (public read-only explorer API) |

The two **not yet implemented** items are the actual remaining core-protocol
work; everything else in this table is done.

## 5. Tech stack

- Node: Rust (tokio, axum, ed25519-dalek)
- Gateway: Node.js (Express)
- Dashboard: static HTML/JS
- Infra: Nginx + Certbot (TLS), systemd (process supervision), Prometheus
- Deployment: bare-metal/VPS via shell scripts (see `docs/DEPLOYMENT_GUIDE.md`)

## 6. Roadmap (next milestones)

1. Real PoI consensus module (replace timer stub)
2. Sybil resistance — staking or allowlist layer for validator identity
3. Gateway-side auth/CORS hardening for write-capable endpoints as they're added
4. Wire agent identity, wallet, and marketplace subsystems to real chain
   state (currently `(sim)` on the dashboard), one at a time
5. Multi-validator public testnet (3+ independently hosted nodes)

## 7. Repository layout

```
node/        Rust core node source + Cargo project
gateway/     Node.js API gateway + dashboard (public/)
monitoring/  Prometheus config, docker-compose
systemd/     Unit files for node + gateway
scripts/     Ordered VPS provisioning/deploy scripts (01–05)
docs/        Deployment guide + changelog of security fixes
