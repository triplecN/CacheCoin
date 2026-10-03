# Wallet

CacheCoin uses Bitcoin Core's descriptor wallets. This is the practical guide:
create, back up, receive, spend, and restore. Nothing here needs a third-party
wallet, and no hardware-wallet path has been tested by this repository.

## Create and back up

```bash
cachecoin-cli createwallet "main"
ADDR=$(cachecoin-cli -rpcwallet=main getnewaddress "" bech32)   # cccn1...
cachecoin-cli -rpcwallet=main backupwallet /media/offline/main-wallet.bak
cachecoin-cli -rpcwallet=main listdescriptors true > /media/offline/main-descriptors.json
```

- `backupwallet` copies the wallet file; restore it by putting it back and
  loading it with `loadwallet`.
- `listdescriptors true` exports the descriptors **including private keys**.
  That file plus the wallet passphrase is the real backup: with it you can
  rebuild the wallet from nothing. Treat it like cash.
- Back up offline, verify the backup opens, and keep a copy outside the
  machine. Losing the descriptors loses the coins; there is no recovery.

## Receive

```bash
cachecoin-cli -rpcwallet=main getnewaddress "" bech32
cachecoin-cli validateaddress <address>          # check before publishing it
```

Use a fresh `cccn1...` address per payment. The legacy `C...` prefix is shared
with an unrelated 2014 altcoin; prefer bech32 and whitelist `cccn1` in any
deposit scanner (`doc/exchange_integration.md` §2).

## Spend

```bash
cachecoin-cli -rpcwallet=main getbalances
cachecoin-cli -rpcwallet=main listunspent
cachecoin-cli -rpcwallet=main sendtoaddress <address> 1.25
cachecoin-cli -rpcwallet=main -named sendtoaddress address=<address> amount=1.25 fee_rate=10
# fee_rate is in sat/vB; never pass conf_target and fee_rate together
```

- Fee-estimator horizons are in blocks on a 60-second chain: `estimatesmartfee 6`
  means about six minutes. The shipped configs set `fallbackfee=0.0001` (10
  sat/vB) because a young chain has little fee data.
- `lockunspent false '[{"txid":"...","vout":0}]'` freezes a coin; `true` unlocks.
- Unconfirmed transactions are inherited Bitcoin Core policy. Treat them as
  replaceable and verify anything you rely on.

## Maturity and PER payouts

- **Coinbase outputs mature after 100 blocks** and cannot be spent before that.
  The subsidy, and every PER payout, is a coinbase output.
- `listunspent` shows immature coins as not spendable. `getbalances` puts them
  under `immature`.
- PER payouts can be dust (below 1000 sat). Sweeping them costs more than they
  are worth; set an economic threshold.

## Restore on another machine

```bash
cachecoin-cli createwallet "restored"
cachecoin-cli -rpcwallet=restored importdescriptors "$(cat main-descriptors.json)"
cachecoin-cli -rpcwallet=restored rescanblockchain    # if the wallet needs history
```

`importdescriptors` takes the same JSON `listdescriptors true` produced. If you
only have a single key, turn it into a descriptor first:

```bash
cachecoin-cli getdescriptorinfo "wpkh(<WIF>)"        # note the checksum
cachecoin-cli -rpcwallet=restored importdescriptors \
  '[{"desc":"wpkh(<WIF>)#<checksum>","timestamp":"now"}]'
```

`scripts/keygen.py --save` generates a keypair offline (WIF plus both
addresses) and refuses to print private keys unless asked; it warns that its
Python point multiplication is not constant-time, so run it on a machine you
trust.

## Shunko is a different mode

Private sending needs `walletbroadcast=0` **and** transactions built with
`add_to_wallet=false`, or the wallet announces them itself and the hand-over is
pointless (`SHUNKO_PROTOCOL.md`). Do not set `walletbroadcast=0` on a node that
also sends normally: it suppresses all wallet broadcasts. Exchanges keep the
default (`doc/exchange_integration.md` §5).

## What is not provided

- No hardware-wallet integration is tested here. Descriptor wallets can in
  principle be watched with external signers, but this repository does not
  document or test a path for it.
- No `dumpwallet` workflow: use `backupwallet` and `listdescriptors true`.
- No recovery service and no seed-phrase format. If you lose the
  descriptors and the wallet file, the coins are gone.
