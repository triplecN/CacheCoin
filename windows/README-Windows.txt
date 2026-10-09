CacheCoin (CCCN) - Windows package: what each file does
=======================================================

CacheCoin App.cmd      Opens CacheCoin.exe, the window (GUI). Needs bin\ and, unless
                       Offline mode is on, Tor + internet. Everyday wallet use.
CacheCoin.exe          The window itself. Start it from "CacheCoin App.cmd". It is
                       listed in version.json and hash-checked like the rest.

Start Node.cmd         Runs launcher\CacheCoin.ps1 -Mode node (node only). Needs bin\,
                       Tor, internet. Safe default, standalone.
Start Mining.cmd       Runs launcher\CacheCoin.ps1 -Mode mining (node + CPU mining +
                       peer). Needs bin\, Tor, internet. Asks how many processors to use
                       and where the coins go: a wallet from Wallet\ (made with
                       Create New Wallet.cmd) or a pasted cccn1 address checked by
                       the node. Mining does not use or change the node's wallet.
                       Mining also accepts incoming Tor connections so other nodes
                       can sync from this computer (default cap: 32 connections,
                       ~5 GB uploaded per day).
Check Status.cmd       Shows chain height, peers, difficulty, disk, and how many
                       blocks this wallet mined (tools\CacheCoin-Status.ps1). Needs
                       a node already running; it does not start one.
Verify Download.cmd    Checks the package before you trust it: version.json,
                       every file hash and the checksum list, and the GPG
                       signature when GnuPG is installed (tools\CacheCoin-Verify.ps1).
PROVENANCE.txt         Where every packaged file came from, and how to check it.
TOR-PIN.txt            The pinned Tor Expert Bundle: version, archive sha256, signing key.
Create New Wallet.cmd  Makes a brand-new wallet offline (no node, no internet):
                       one modern segwit address (cccn1...) and its private key.
                       Option 1 saves it to Wallet\cachecoin-wallet-<date>.txt next
                       to this program; option 2 shows it on screen so you can copy
                       it down. You can make as many wallets as you want.
                       (tools\CacheCoin-NewWallet.ps1)

launcher\CacheCoin.ps1 The command-line launcher behind the files above. Run it with:
                       powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1
                       Flags: -Mode node|mining, -Stop, -Takeover, -Silent,
                       -RunSeconds N, -SelfTest, -EnableAutostart, -DisableAutostart.
                       (Older builds also shipped CacheCoin.cmd; it has been removed.)

Shared facts:
- Run one controller at a time: the launcher and the window share
  Local\CacheCoinLauncher and the data folder %APPDATA%\CacheCoin. If another
  controller (the window or another launcher) is running, the launcher offers to
  close it and continue here; -Takeover does that without asking.
- No seed phrase. Wallets are cachecoind descriptor wallets (the app uses
  "main"). Backups: the app's recovery file plus wallet .bak, a Create New
  Wallet .txt file, or the manual .bak plus descriptor JSON. Main-network
  private strings start with 2EQ, not xprv.
- Tor is required for every networked mode; without it the node cannot connect.
- Accepted limits of the launcher's checks are listed in docs\SECURITY.md, section "The Windows package".
