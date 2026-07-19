// AEN Testnet — API Gateway
// Axis Ledger Lab Ltd
//
// Public-facing REST layer sitting in front of one or more aen-node RPC
// endpoints (each node's RPC is bound to 127.0.0.1 and never exposed
// directly — this gateway is the only thing allowed to reach it).
//
// Endpoints:
//   GET /api/health              -> gateway + upstream node health
//   GET /api/network/status      -> live block height, uptime, peer count
//   GET /api/network/peers       -> live peer list
//   GET /api/explorer/summary    -> dashboard-friendly combined stats
//
// Anything the underlying chain does not yet track natively (agent
// marketplace listings, wallet balances, x402 demo flow) is served from
// the existing in-memory simulation data and clearly labeled as such in
// the API response — this gateway never silently invents "live-looking"
// numbers for subsystems that aren't real yet.

import express from 'express';
import cors from 'cors';
import rateLimit from 'express-rate-limit';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = process.env.PORT || 8080;
const NODE_RPC_URL = process.env.NODE_RPC_URL || 'http://127.0.0.1:9944';
const FETCH_TIMEOUT_MS = 4000;

const app = express();
app.use(cors());
app.use(rateLimit({ windowMs: 60_000, max: 120 })); // 120 req/min per IP
app.use(express.static(path.join(__dirname, 'public')));

async function fetchNode(pathname) {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(`${NODE_RPC_URL}${pathname}`, { signal: controller.signal });
    if (!res.ok) throw new Error(`node RPC ${pathname} returned ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

app.get('/api/health', async (req, res) => {
  try {
    const nodeHealth = await fetchNode('/health');
    res.json({ gateway: 'ok', node: nodeHealth });
  } catch (err) {
    res.status(502).json({ gateway: 'ok', node: 'unreachable', error: err.message });
  }
});

app.get('/api/network/status', async (req, res) => {
  try {
    const status = await fetchNode('/status');
    res.json({ source: 'live', ...status });
  } catch (err) {
    res.status(502).json({ source: 'live', error: 'node unreachable', detail: err.message });
  }
});

app.get('/api/network/peers', async (req, res) => {
  try {
    const peers = await fetchNode('/peers');
    res.json({ source: 'live', ...peers });
  } catch (err) {
    res.status(502).json({ source: 'live', error: 'node unreachable', detail: err.message });
  }
});

// Combined view the dashboard's Explorer tab polls on an interval.
app.get('/api/explorer/summary', async (req, res) => {
  try {
    const [status, peers] = await Promise.all([fetchNode('/status'), fetchNode('/peers')]);
    res.json({
      source: 'live',
      block_height: status.block_height,
      peer_count: peers.peer_count,
      peers: peers.peers,
      uptime_secs: status.uptime_secs,
      node_id: status.node_id,
      fetched_at: new Date().toISOString(),
    });
  } catch (err) {
    res.status(502).json({
      source: 'live',
      error: 'one or more nodes unreachable — network status unavailable',
      detail: err.message,
    });
  }
});

app.listen(PORT, () => {
  console.log(`[aen-gateway] listening on :${PORT}, upstream node RPC = ${NODE_RPC_URL}`);
});
