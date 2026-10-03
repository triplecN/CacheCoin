# Shunko Protocol (瞬鬨)

Network-origin privacy transport for CacheCoin (CCCN): hides which node first handed a transaction, with a public ledger. Automatic targets trust addrman; see the limits in `SHUNKO_PROTOCOL.md`.

Shunko hides *who sent a transaction and from where*. It does not hide *what* was sent: the
ledger stays an ordinary, auditable UTXO chain. It is a transport-layer design only and changes
no consensus rule.

## Files

1. **[`SHUNKO_PROTOCOL_SPECIFICATION.md`](SHUNKO_PROTOCOL_SPECIFICATION.md)**: what Shunko does,
   the threat model, what it does not protect, and prior art.
2. **[`SHUNKO_INTEGRATION_GUIDE.md`](SHUNKO_INTEGRATION_GUIDE.md)**: how it is implemented in the
   node (patches `0006`, `0010`, `0015`, `0016`, `0017`, `0019`, `0020`) and how to use it.
3. **[`shunko_node_mesh.py`](shunko_node_mesh.py)**: a dependency-free model that
   shows why a "first announcer" spy can locate a normal sender but not a Shunko sender.
   Run with `python shunko_node_mesh.py`.

## Status

Version 1 is implemented and tested (`tests/shunko_regtest.py`). Shunko builds on public ideas,
Dandelion/Dandelion++ and the "private broadcast" work in Bitcoin Core. It is opt-in, not default:
ordinary sends still announce normally; private sending needs `scripts/sendtoshunko.sh` (or
`shunkobroadcast`) plus `walletbroadcast=0` and Tor — see [`SHUNKO_PROTOCOL.md`](../SHUNKO_PROTOCOL.md).
It is open source like the rest of the project: improvements are welcome.
