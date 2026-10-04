# Start here

So you found this repo. Here's the two-minute version.

CacheCoin is a CPU-mined proof-of-work coin, released as-is under MIT. Ordinary CPUs mine it, small miners share fee income through PER, and transactions can be relayed over Tor with Shunko.

The idea is that anyone with a computer should still be able to mine. Early Bitcoin could be mined on a CPU; that era ended, and mining moved to machines most people will never own. CPU mining is much slower per hash, and CacheCoin accepts that.

**Why this exists.** A 4 GB computer can mine in light mode (the node needs a 256 MiB RandomX cache; the 2 GiB dataset is only for external fast miners), and you can leave it running in the background while you browse or play, giving it only the capacity you choose. It is not perfectly fair -- a machine that keeps the full RandomX dataset in RAM is several times faster per core (README section 1.6) -- but a small effort should still count, without buying anything special. That is the whole point.

The rules are written down and the numbers can be reproduced. The test suite has 15 suites and mines several thousand blocks under real RandomX, `doc/verification.md` records the exact hashes and results of the verified series, and `SECURITY.md` lists what it doesn't cover. CacheCoin was started by triplecN and released under MIT. From here on it belongs to whoever runs it, forks it and makes it better. Everything needed to run, verify and fork it is in this repository.

Some things to know before you spend time on it.

**What to expect.** Mining can pay nothing for weeks, and the fee-sharing pool can sit empty for a month. CacheCoin is open-source software, provided as is under the MIT license; nothing here is financial advice, an offer or a promise of return.

**Build from source.** The supported path is `bash scripts/build_linux.sh` on Ubuntu/WSL2 (see below), or `doc/build-windows.md` on native Windows. Signed releases attach the Linux binaries and `SHA256SUMS.txt`; a Windows package can be attached separately with its own notes and hashes (`windows/README.md`). CI artifacts are a different thing: they expire after 90 days and need a GitHub login. Whatever route you take, verify the files before running them -- it is how you know they were not tampered with on the way to you:

```powershell
Get-FileHash cachecoind.exe -Algorithm SHA256
# compare the output with the matching line in SHA256SUMS.txt
```

(Why SHA-256 and not MD5? MD5 is broken for integrity checks. If anyone hands you an MD5 checksum for software, don't trust that process.)

No prebuilt binary? On Ubuntu, or WSL2 Ubuntu on Windows, it takes one command and 30-60 minutes: `bash scripts/build_linux.sh`. WSL2 is the supported Windows path. A native Windows build script is not provided, and the `.exe` files are outside this repository's test suites. See [`doc/build-windows.md`](doc/build-windows.md) if you want to build them yourself.

**Tor has to be running before the node will connect to anything.** CacheCoin is Tor-only: it has no DNS seeds, no fixed seeds, and by default it listens on no ports at all. (The Windows launcher offers an opt-in "help other nodes connect" setting; when enabled, the node binds only `127.0.0.1`, never a public interface.) A clearnet config exists (`config/cachecoin-clearnet.conf`) if you choose to use one. `config/cachecoin.conf` points at `127.0.0.1:9050`, which is the port the Tor Expert Bundle and a system Tor daemon use. **Tor Browser uses a different port, 9150.** If you installed Tor Browser, change `proxy=` in your config to `127.0.0.1:9150` or your node will start and sit at zero peers forever without saying why.

**Three things that tend to surprise people:**

1. *Mining usually pays nothing.* Finding a block is a lottery. Weeks without a block are normal for solo mining, not a sign your setup is broken. The PER ticket system (README §1.5) lets small miners earn fee shares without ever finding a block, but only if there are fees to share.
2. *"Private sending" does not hide money.* Amounts, addresses and flows stay on the public ledger forever. Shunko only hides which network node first handed a transaction onward. Read §4 of `SHUNKO_PROTOCOL.md` ("What Shunko does not protect") before you trust it with anything.
3. *Questions go to the code and the community.* Vulnerability reports go through `SECURITY.md`. Everything else goes in public issues, where anyone can answer.

**Words you'll keep seeing:**

- *Node (`cachecoind`)*: the program that checks blocks and passes them along.
- *Miner*: whoever finds a block keeps its subsidy plus half its fees.
- *PER reservoir*: the other half of the fees, split every 28 days among ticket miners.
- *Shunko*: hands your payment to strangers over Tor, so your own node isn't the one seen sending it.
- *Explorer*: `python3 explorer/app.py`, a local web page of blocks and balances.

Still interested? `README.md` §7 gets a node running.