-- CacheCoin (CCCN) explorer database schema (SQLite)
-- The explorer is a cache of the node's chain: delete explorer.db at any time and
-- it is rebuilt from the node over RPC.

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS blocks (
    height INTEGER PRIMARY KEY,
    hash TEXT UNIQUE NOT NULL,
    prev_hash TEXT,
    merkle_root TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    bits TEXT NOT NULL,
    nonce INTEGER NOT NULL,
    difficulty REAL DEFAULT 1.0,
    tx_count INTEGER DEFAULT 0,
    size INTEGER DEFAULT 0,
    total_fees INTEGER DEFAULT 0,      -- sum of transaction fees in the block (Cache)
    coinbase_value INTEGER DEFAULT 0,  -- sum of coinbase outputs (Cache)
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS transactions (
    txid TEXT PRIMARY KEY,
    block_height INTEGER NOT NULL,
    block_hash TEXT NOT NULL,
    version INTEGER NOT NULL,
    size INTEGER NOT NULL,
    locktime INTEGER NOT NULL,
    is_coinbase INTEGER DEFAULT 0,
    total_output INTEGER DEFAULT 0     -- Cache
);

CREATE TABLE IF NOT EXISTS tx_outputs (
    txid TEXT NOT NULL,
    vout_index INTEGER NOT NULL,
    value INTEGER NOT NULL,            -- Cache (1 CCCN = 100,000,000 Cache)
    script_pubkey TEXT NOT NULL,
    address TEXT,                      -- NULL for non-standard, "OP_RETURN" for data outputs
    block_height INTEGER NOT NULL,
    spent_txid TEXT,                   -- NULL while unspent
    PRIMARY KEY (txid, vout_index)
);

CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tx_block ON transactions(block_height);
CREATE INDEX IF NOT EXISTS idx_outputs_address ON tx_outputs(address);
CREATE INDEX IF NOT EXISTS idx_outputs_height ON tx_outputs(block_height);
CREATE INDEX IF NOT EXISTS idx_outputs_spent ON tx_outputs(spent_txid);
-- Paged address view (ORDER BY block_height DESC ...) and unspent-balance SUM:
-- without these the whale-address queries sort/scan without help from LIMIT.
CREATE INDEX IF NOT EXISTS idx_outputs_addr_page ON tx_outputs(address, block_height DESC, txid, vout_index);
CREATE INDEX IF NOT EXISTS idx_outputs_addr_unspent ON tx_outputs(address, spent_txid);
