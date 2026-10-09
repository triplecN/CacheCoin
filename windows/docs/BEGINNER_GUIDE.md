# CacheCoin for Beginners (Windows)

This guide is for people who are not programmers. You only need to click, copy
and paste. Every command is written exactly as you should type it.

CacheCoin (CCCN) is a small cryptocurrency that runs over Tor. The Windows
package contains a full node, a wallet and (optionally) a miner. There is no
company, no support line and no seed phrase. Read the safety rules below.

The package has six double-click files:

- `CacheCoin App.cmd` - the window: wallet, mining page (needs `CacheCoin.exe`).
- `Start Node.cmd` - run the node only (safe default).
- `Start Mining.cmd` - run the node and mine (it asks how many CPU threads and where the coins go).
- `Create New Wallet.cmd` - make a new wallet offline (one address and its private key).
- `Check Status.cmd` - show block, peers and balance.
- `Verify Download.cmd` - check the package (file list, hashes and signature) before trusting it.

The command-line launcher behind them is `launcher\CacheCoin.ps1` (an older `CacheCoin.cmd` was removed). `PROVENANCE.txt` lists where every packaged file came from and how to check it.

---

## Safety rules (read this first)

1. **Your wallet has no seed phrase.** The wallet file *is* the wallet. If you
   lose every copy of it, your coins are gone forever. Nobody can recover them.
2. **Anyone who has your backup file or your private keys can take your coins.**
   Treat those files like cash.
3. **Save your backup offline.** A USB stick or another disk, kept somewhere
   safe, is the right place. Never email it, never upload it to cloud storage
   (OneDrive, Google Drive, Dropbox...), never put it in a chat, never take a
   screenshot of it and never share your screen while it is visible.
4. **Mining is a lottery, not a salary.** Your CPU competes with everyone else.
   You may find a block, you may never find one. It costs electricity either way.
5. **This is not financial advice.** The software is provided as is, with no
   warranty and no promise of profit.

---

## What you need

- A Windows 10 or 11 computer.
- The package `CacheCoin-Windows-<version>.zip` from the GitHub release page.
- A USB stick (recommended) for the wallet backup.
- Time: the first start can take a few minutes, because the node syncs over Tor.

---

## Part 1 - Start the node (Node only mode)

This is the safe way to run CacheCoin: your computer helps the network, but it
does not mine and does not use much CPU.

1. Download the ZIP from the release page.
2. Check the file first. Open `docs\VERIFY.txt` and follow it. It only takes a
   minute and it proves the download arrived unchanged.
3. Right-click the ZIP, choose **Extract All**, and open the extracted folder
   `CacheCoin-Windows-<version>`. Do not run the program from inside the ZIP.
4. Double-click **Start Node** (the file `Start Node.cmd`).
5. If Windows shows "Windows protected your PC", click **More info**, then
   **Run anyway**. (This happens because the program has no paid Windows
   signature.)
6. On the first start the launcher asks two yes/no questions: whether to
   accept incoming Tor connections (press Enter for no) and whether to start
   CacheCoin automatically when you log in (press Enter for no). `Start Node.cmd`
   already selects node-only mode, so there is no mode question.
7. Wait. The window shows the sync progress. When it says
   `Up to date at block ...`, you are done.

Your data lives in `%APPDATA%\CacheCoin` (usually
`C:\Users\<you>\AppData\Roaming\CacheCoin`). Do not delete that folder while
the node is running.

You can close the window at any time. The node keeps running; the next start
attaches to it. To stop it, see Part 6.

---

## Part 2 - Start mining (Node + mining mode)

Only start mining if you understand it is a lottery.

1. Double-click **Start Mining** (the file `Start Mining.cmd`). Or open
   PowerShell in the CacheCoin folder and run:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 -Mode mining
   ```

2. The launcher asks how many processors mining should use (type a number, or
   press Enter for a small recommended number). The rule:
   - a number below what this computer can run is used as typed;
   - typing exactly the maximum uses every processor;
   - a number above the maximum is capped to maximum-1 (leaving one for
     Windows; on a single-core computer the count stays at 1).
   More processors mine faster and make the computer hotter and louder.

3. Next it asks where the mined coins should go:
   - type **1** to use a wallet from the `Wallet` folder (made with
     `Create New Wallet.cmd`; the newest `.txt` file is used);
   - type **2** to paste your own modern segwit address (it starts with
     `cccn1`). The node checks the address, then shows it and asks you to press
     Enter to confirm. **A wrong address cannot be undone.** If it is an
     exchange address, the exchange must credit you.

4. Mining starts. The window shows `Mining: N worker(s)`.

Mining is a package: your computer runs a full node, mines, and also serves as
a peer. It publishes its own onion address and accepts incoming Tor connections
so other nodes can sync from it; that is what keeps the network alive without
depending on one server. Tor still hides your IP, but the node's onion address
is public, like any peer. Total connections are capped at 32 (incoming plus
outgoing) and the node serves at most about 5 GB per day, so it stays light.

Mining does not use or change the node's own wallet, so no wallet backup is
needed just to mine. Back up the wallet that receives the coins (Part 3).

The mode is remembered. The next time, double-clicking **Start Mining** starts
mining again (the launcher asks again; the saved answers are used only when the
node starts automatically in the background).
To go back to node-only, double-click **Start Node** once.

To see where the coins go later, open
`%APPDATA%\CacheCoin\logs\launcher.log` and search for `Mining address:`.

---

## Part 3 - Save your wallet backup (the most important step)

A backup is needed for any wallet that holds coins. Mining does not use or
change the node's own wallet, so the launcher does not ask for a backup before
mining. The wallets you can have:

- **Create New Wallet.cmd** saves one address and its private key to
  `Wallet\cachecoin-wallet-<date>.txt` (option 1). Copy that file to a USB
  stick or another disk, not the same disk as the program. Option 2 shows the
  key on screen instead: write it down.
- **The CacheCoin App** (the window) has its own wallet `main` with a backup
  page. Use it if you keep coins there.
- The command-line wallet `main` (used by `cachecoin-cli`) is backed up with
  the manual commands in `docs\BACKUP.txt`.

Rules:

- Anyone who has the wallet file, the WIF or the private key can take the
  coins. Treat them like cash.
- Save backups offline: a USB stick or another disk, not the same disk as the
  program. Never email, chat or cloud-sync them.
- If you receive more coins later, make a fresh backup.
- There is no seed phrase and no recovery service. Test your restore before
  you need it; the tested steps are in `docs\BACKUP.txt`.

---

## Part 4 - Create a new wallet offline (advanced, optional)

**Create New Wallet.cmd** makes a brand-new single key offline: no node and no
internet are needed. You get one modern segwit address (`cccn1...`), its private
key, the WIF and the public key. Option 1 saves everything to a `.txt` file in a
`Wallet` folder next to the program; option 2 shows it on screen so you can copy
it down. You can make as many wallets as you want.

To open such a wallet in CacheCoin: first screen -> "Forgot your password?" ->
"From a private key" -> paste the WIF -> choose a password. One key restores one
address only; use a recovery file from the CacheCoin App when you have one.

**WARNING: anyone who sees the private key or the WIF can take those coins.
There is no undo.** Keep the file or the paper offline.

To print the keys of the wallet the node already has (advanced):

1. Open PowerShell in the CacheCoin folder.
2. An encrypted wallet must be unlocked first (`walletpassphrase`), then run:

   ```
   .\bin\cachecoin-cli.exe -rpcwallet=main listdescriptors true
   ```

3. The output is JSON. The strings that start with `2EQ` (`tprv` on a test
   build) are your private keys. The CacheCoin App's recovery file (or the manual
   backup in `docs\BACKUP.txt`) contains the same information.

Rules for these keys:

- Copy them **only** to offline media: a USB stick, or paper in a safe.
- Never email, chat, cloud-sync, screenshot or type them into a website.
- Do not print them on a computer you do not trust (malware can read them).
- When you are done, close PowerShell and clear the screen.

There is no seed phrase and no recovery service. If you lose all copies of your
backup and keys, the coins are gone. Test your restore on a second computer
**before** you need it - the steps are in `docs\BACKUP.txt`.

---

## Part 5 - Check what your node is doing (127.0.0.1)

The Windows package has no built-in web page. The quick checks are:

- **Check Status.cmd**: double-click it. It shows the block, peers and balance.
- **Tray icon** (bottom-right of Windows): hover it. The tooltip shows
  `CacheCoin - N peers, block H`. Right-click it to pause mining or stop.
- **Launcher log:** `%APPDATA%\CacheCoin\logs\launcher.log`.
- **PowerShell in the CacheCoin folder:**

  ```
  .\bin\cachecoin-cli.exe getblockcount
  .\bin\cachecoin-cli.exe getconnectioncount
  .\bin\cachecoin-cli.exe -rpcwallet=main getbalances
  ```

**Optional block explorer at 127.0.0.1.** The repository includes a small web
explorer (`explorer/app.py`). It is not part of the Windows ZIP because it
needs Python 3. If you have Python 3 installed:

```
python3 explorer/app.py
```

Then open `http://127.0.0.1:8080` in your browser. It listens on your own
computer only (localhost); do not expose it to the internet.

---

## Part 6 - Stop CacheCoin and manage autostart

- Interactive window: right-click the tray icon and choose **Stop CacheCoin**.
- No window or tray (automatic start at login):

  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 -Stop
  ```

- Stop it from starting at login:

  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 -DisableAutostart
  ```

- Turn the login start back on:

  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File launcher\CacheCoin.ps1 -EnableAutostart
  ```

Never delete the data folder while the node is running.

---

## Part 7 - If you lose your wallet

Open `docs\BACKUP.txt` and follow the RESTORE steps from top to bottom. Do it
in PowerShell, exactly as written. The restore uses one of your two backup
files; that is why Part 3 matters so much.

---

## Questions people ask

**"How long until I find a block?"**
Nobody can say. Solo mining is a lottery. It can be weeks, or never. Check
`Blocks found` in the launcher window.

**"The balance says `wallet not loaded`. Where are my coins?"**
Node only mode does not load a wallet, so there is no balance to show. The
CacheCoin App loads its own wallet when it is open. If you mine to a Wallet
folder address (Create New Wallet.cmd), the coins belong to that address, not
to this node's wallet; to see or spend them, open the WIF in the app via
"Forgot your password?" -> "From a private key".

**"My clock is wrong. Does it stop mining?"**
No. The launcher only warns. If Windows time is wrong by more than 5 minutes,
a block you find can be rejected by the network, so fix your clock anyway:
Settings > Time & Language > Date & time > Sync now.

**"Can I run this on more than one computer?"**
Yes, but each computer has its own wallet and its own backup. Coins mined on
one computer do not appear on the other.

**"Is this private?"**
The node connects only over Tor, and the launcher binds incoming connections to
localhost. Still, never share your wallet files or private keys.

---

## Where to read more

- `docs\START_HERE.txt` - short version of this guide.
- `docs\BACKUP.txt` - backup and tested restore commands.
- `docs\VERIFY.txt` - check the download and the signatures.
- `docs\SECURITY.md` - security notes; its "The Windows package" section lists the accepted limits.
