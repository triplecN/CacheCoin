# CacheCoin node deployment: VPS seed node + home miner over Tor

```
 HOME PC (Linux, or WSL on Windows)             VPS (Ubuntu 24.04)                     Other nodes
 ┌──────────────────────────────┐   Tor only   ┌──────────────────────────────┐   Tor   ┌───────────┐
 │ cachecoind  (mining node)    │ ───────────► │ cachecoind  (seed / relay)   │ ◄──────►│ anyone    │
 │  onlynet=onion               │  connect=    │  onlynet=onion               │         │ running a │
 │  addnode=<seed>.onion:29333   │  <vps>.onion │  listenonion=1  -> xxx.onion │         │ node      │
 │  listenonion=1 -> yyy.onion       │              │  binds 127.0.0.1 only        │         └───────────┘
 │ deploy/home/mine.sh          │              │  no mining, no open ports    │
 │  -> generatetoaddress        │              │  systemd: cachecoind.service │
 └──────────────────────────────┘              └──────────────────────────────┘
```

* **VPS**: keeps the full chain online 24/7 and relays blocks. It does not mine
  (most VPS providers forbid mining). It is reachable only through its `.onion`
  address, and under correct Tor-only configuration its IP address is not used for
  peer-to-peer traffic (misconfiguration can still leak it — verify onlynet/proxy).
* **Home PC**: mines and also serves as a peer. It bootstraps from the published
  seed (`addnode=`) through Tor and accepts incoming Tor connections, so other
  nodes can sync from it. Tor hides the home IP; the node's own `.onion` address
  is public, like any peer. Connection count and daily upload are capped
  (`maxconnections=32`, `maxuploadtarget=5000`).

Ports: P2P `29333`, RPC `29332` (local only), Tor onion target `29334` (local only).

## 1. Build the binaries

On the VPS (and on the home PC), from the project directory:

```bash
bash scripts/build_linux.sh
```

This produces a portable build (no `-march=native`), so a binary built on one
machine does not crash with "illegal instruction" on a different CPU. Building
needs about 2 GB of RAM; on a 1 GB VPS add swap first (`setup_vps.sh` later keeps
it enabled after reboots):

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
```

Binaries built on Ubuntu 24.04 can be copied to another Ubuntu 24.04 machine
instead of rebuilding; other releases should build locally.

## 2. VPS: install the seed node

```bash
sudo bash deploy/vps/setup_vps.sh
```

The script enables swap on a VPS with less than about 2.5 GB of RAM (so the node
is not killed when memory runs short), installs Tor, creates the `cachecoin`
system user and checks that it can read Tor's control cookie, installs
`/etc/cachecoin/cachecoin.conf` and the `cachecoind` systemd service, then prints
the node's onion address, for example:

```
onion address : abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion:29333
```

Back up `/var/lib/cachecoind/onion_v3_private_key`. With it the same onion
address can be restored on any new VPS; without it the address is lost for good.

There are no DNS seeds, so other people can only join if they know a node. To let
them, the current seeds are published in the README (`Seeds` row); they add
`addnode=<address>.onion:29333` to their `cachecoin.conf`, together with
`proxy=127.0.0.1:9050` and `onlynet=onion`.

Publish the address only after a fresh node has actually synced through it. Run
at least two independent seeds on different providers before any announcement:
one seed is a single point of failure for the whole network. Do not mine on the
seed node (the shipped config sets `disablewallet=1`); mine from a separate
machine, to an address you publish, so the launch is transparent.

Disk space: the chain grows with use, up to 2 MB per block (about 2.9 GB per day)
if every block were full. Check `df -h /var/lib/cachecoind` now and then. A seed
node should keep every block so that new nodes can download them. Do not set `prune=`:
the node refuses to start with pruning because PER payouts verify blocks up to a
full 28-day epoch back, far beyond any prune window.

Check the node:

```bash
sudo -u cachecoin cachecoin-cli -datadir=/var/lib/cachecoind -conf=/etc/cachecoin/cachecoin.conf getblockchaininfo
journalctl -u cachecoind -n 50      # the log (journald caps its size; there is no debug.log)
```

The first log lines show the RandomX mode and the self-test result, for example
`RandomX proof-of-work: JIT (W^X), self-test passed`.

## 3. Home PC: node + peer + miner behind Tor

The home node is the whole package in one process: it mines and it also serves
other nodes (it publishes its own onion service and accepts incoming Tor
connections). Connection count and daily upload are capped in the config.

On Windows, the native package (`windows/README-Windows.txt`) runs this same
node+peer+miner setup without WSL, systemd or a manual Tor install.

```bash
sudo apt-get install -y tor
# Let the node create its onion service through Tor's control port. The cookie
# must be group-readable for the user that runs cachecoind. The marker makes a
# re-run safe: the lines are appended only once.
if ! grep -q "CacheCoin home: lines appended" /etc/tor/torrc; then
sudo tee -a /etc/tor/torrc >/dev/null <<'EOF'

# CacheCoin home: lines appended by deploy/README.md section 3
ControlPort 127.0.0.1:9051
CookieAuthentication 1
CookieAuthFileGroupReadable 1
EOF
fi
sudo systemctl restart tor
sudo usermod -aG debian-tor "$USER"     # log out and back in once, so the group applies
mkdir -p ~/.cachecoin
cp deploy/home/cachecoin.conf ~/.cachecoin/cachecoin.conf
# The shipped addnode= seeds are already in the file; add more as the network grows.
cachecoind -daemon
cachecoin-cli -rpcwait getconnectioncount   # 1 or more (a seed, or other peers)
# After a minute, the node's own onion address appears here:
cachecoin-cli getnetworkinfo | grep -A8 localaddresses
```

**Keep the clock right.** A node rejects blocks stamped more than 10 minutes
ahead of its own clock, and peers cannot correct it. Check `date -u` against a
reliable clock before mining. Under WSL the clock can fall behind after Windows
sleeps or hibernates: `sudo hwclock -s` (or `wsl --shutdown` from Windows and
reopening WSL) resyncs it.

### Optional: an unpublished entrance for your home miner (still Tor-only)

The public onion address accepts anyone, and a node has a limited number of
incoming slots; when they are full it drops one of the newer connections. You can
give your home miner a second onion address that is never published, on a port
with gentler ban treatment:

1. On the VPS, add to `/etc/tor/torrc`, restart Tor and read the new address:
   ```
   HiddenServiceDir /var/lib/tor/cachecoin-home/
   HiddenServicePort 29333 127.0.0.1:29335
   ```
   ```bash
   sudo systemctl restart tor && sudo cat /var/lib/tor/cachecoin-home/hostname
   ```
2. Add `whitebind=noban@127.0.0.1:29335` to `/etc/cachecoin/cachecoin.conf` and
   run `sudo systemctl restart cachecoind`.
3. On the home PC, replace the `addnode=` seed with
   `connect=<that address>:29333`. `connect=` uses only the addresses listed
   there and disables the other peers, so this step is optional.

Keep that address to yourself: connections via this unpublished entrance are exempt
from automatic banning (noban) — use it only for your own miner, monitor it, and
revoke it if abused.

## 4. Mine

```bash
bash deploy/home/mine.sh <your-cccn1-address>
```

The script refuses to start if the address is invalid or if the node has no
peer, so blocks are never mined into a private dead end; while the VPS is
unreachable it pauses and resumes by itself. Blocks 1-60 are mined at the minimum
difficulty; after that LWMA adjusts difficulty every block toward one block per
60 seconds.

On a brand-new chain (before block 1), `getblockchaininfo` shows `"initialblockdownload": true`:
the genesis block is more than 24 hours old, so the node assumes it is still
catching up. That is expected and does not stop the built-in miner; it changes to
`false` once a block with a current timestamp is mined. Mine the first blocks with
`generatetoaddress` (as `mine.sh` does): `getblocktemplate` refuses work while the
node considers itself syncing, which on a fresh chain lasts until the tip is fresh.

The built-in miner (`generatetoaddress`) hashes RandomX in light mode on one core
per loop. Run `mine.sh <address> 2` to use two cores. Each loop keeps one RPC call
busy, so use fewer loops than `rpcthreads` (8 in `deploy/home/cachecoin.conf`).

### Earning a share without finding a block (PER tickets)

Finding whole blocks is high-variance: a slow CPU can mine for weeks and find none.
Entropy tickets (see the main README, section 1.5) let any CPU earn a share of the
28-day fee reservoir. Mine tickets in a loop instead of, or alongside, block mining:

```bash
while cachecoin-cli getconnectioncount | grep -qv '^0$'; do
  cachecoin-cli generateperticket <your-cccn1-address> 20000 >/dev/null
done
```

Each ticket is anchored to a recent block and relayed to your peers; whoever mines
the next block embeds it, and your share is paid to your address one epoch (28 days)
later. Use the same address you control; check the reservoir with
`cachecoin-cli getperinfo`.

`generateperticket` re-anchors to the current tip every 1024 nonces, so a ticket
found after a long search is still anchored to a recent block and stays valid. The
`maxtries` argument is a budget per call: 20000 is roughly seven minutes of
light-mode RandomX on one core, which keeps the call from holding an RPC thread for
hours, and the loop starts the next call when it returns. Your expected wait is about
3.75 seconds divided by your share of the network hash rate: 1% waits minutes, 0.01%
waits hours. The payout depends on the fees collected, which can be zero.

## 5. Send with network-origin privacy (Shunko; amounts and addresses stay public)

The home configuration sets `walletbroadcast=0`: the wallet never announces its
own transactions. Send with:

```bash
bash scripts/sendtoshunko.sh <cccn1-address> <amount>
```

The payment is handed to other nodes over one-shot Tor connections (see
[SHUNKO_PROTOCOL.md](../SHUNKO_PROTOCOL.md)) and shows up in your wallet once it
is mined. Ask every payer for a new address, and give a new one each time.

While this home node listens, the automatic hand-over still excludes connected
peers and every node listed with `addnode=`, but an inbound peer cannot be matched
by address. If that matters to you, name the targets you trust explicitly
(SHUNKO_PROTOCOL.md section 4) instead of relying on the automatic path.

## If the network splits

With few independent nodes, an outage can leave miners on different branches for a while.
When they reconnect, a node refuses a branch that would undo more than 5 of its
blocks (see the main README) and `getblockchaininfo` shows a warning. The split
heals by itself once one branch is 36 blocks past the point where the two diverged, counted in height rather than in work. To end it at once on
a node that is on the losing side:

```bash
cachecoin-cli getchaintips                     # find the fork and both branch tips
cachecoin-cli invalidateblock <first block after the fork on this node's branch>
```

**After the override, check your payments before you re-send anything.**
Transactions that were confirmed on the branch you just abandoned are no longer in
a block, and they normally come back on their own: measured on regtest,
`gettransaction` drops to `confirmations: 0` and `getmempoolinfo` counts them
again. Shunko payments do too, because a Shunko transfer is delivered as an
ordinary `tx` message, so the receiving node already had it in its mempool.

```bash
cachecoin-cli getchaintips          # both branches, one marked "invalid"
cachecoin-cli gettransaction <txid> # confirmations 0 = not in a block any more
cachecoin-cli getrawmempool         # is it back, waiting to be mined again?
```

**Do not re-send a payment whose confirmations dropped to 0 until you have
checked the mempool — that pays twice.** A payment genuinely needs re-sending
only if it did not come back, which happens when an input was spent by another
branch or it is no longer above the fee floor. Delete `explorer/explorer.db` on
every explorer node afterwards, or it keeps serving the abandoned branch.

A node that restarts after more than 24 hours offline, or that is started with
`-reindex`, does not remember a branch it refused: like a new node it follows the
branch with the most work. Avoid `-reindex` while the warning is shown. (Pruning is
disabled on CacheCoin, so every node keeps the blocks needed to follow a heal.)

## Operational-privacy checklist before publishing (lawful use only)

* **Push via `git` from the command line, never drag-and-drop through the GitHub website.**
  `.gitignore` only protects you when you push with `git`; the web uploader ignores
  `.gitignore` and publishes everything you drop — including `private/`, internal notes
  and audit reports (they can quote your payout address), wallet files, key backups and
  anything personal. Move all of that out of the project folder before publishing.
* If you require pseudonymity for personal safety, consider a separate publishing
  identity (account, e-mail, git `user.name`/`user.email`) that is not linked to you.
  Git also records your timezone in every commit: commit with `TZ=UTC` or set
  `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` in UTC. Comply with applicable laws in your
  jurisdiction; nothing here facilitates illicit activity.
* Before pushing, list exactly what will be published: `git ls-files`.
* Limit personal metadata exposure when renting and administering the VPS (e.g. access
  it over Tor or a VPN). This guide is for lawful research operation only and does not
  advise evading legal obligations, sanctions, tax, or KYC/AML requirements.
* Do not publish binaries built on your own machine without checking them:
  build paths such as `/home/<user>/...` end up inside the executables.
* Keep the payout address's private key offline and backed up.
