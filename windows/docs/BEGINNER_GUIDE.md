# CacheCoin for Beginners (Windows)

This guide is for people who are not programmers. You only need to click, copy
and paste. Every command is written exactly as you should type it.

CacheCoin (CCCN) is a small cryptocurrency that runs over Tor. The Windows
package contains a full node, a wallet and (optionally) a miner. There is no
company, no support line and no seed phrase. Read the safety rules below.

The package has four double-click files:

- `Start Node.cmd` - run the node only (safe default).
- `Start Mining.cmd` - run the node and mine (it asks for a backup first).
- `My Keys and Backup.cmd` - save your wallet backup or show your private keys.
- `Check Status.cmd` - show block, peers and balance.

`CacheCoin.cmd` is the classic entry point behind them; it still works.

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
4. Double-click **Start Node** (the file `Start Node.cmd`). If you prefer the
   classic way, double-click `CacheCoin` and choose `1) Node only`.
5. If Windows shows "Windows protected your PC", click **More info**, then
   **Run anyway**. (This happens because the program has no paid Windows
   signature.)
6. When asked how to run, type **1** and press Enter: `1) Node only`.
7. Wait. The window shows the sync progress. When it says
   `Up to date at block ...`, you are done.

Your data lives in `%APPDATA%\CacheCoin` (usually
`C:\Users\<you>\AppData\Roaming\CacheCoin`). Do not delete that folder while
the node is running.

You can close the window at any time. The node keeps running; the next start
attaches to it. To stop it, see Part 6.

---

## Part 2 - Start mining (Node + mining mode)

Only start mining if you understand it is a lottery. Before mining can begin,
you must save and confirm a wallet backup (Part 3); the launcher enforces this
on purpose, to protect your coins.

1. Double-click **Start Mining** (the file `Start Mining.cmd`). Or open
   PowerShell in the CacheCoin folder and run:

   ```
   CacheCoin.cmd -Mode mining
   ```

2. The launcher loads (or creates) your wallet. You do **not** type any address:
   the wallet automatically creates a modern SegWit address that starts with
   `cccn1q...`. Mining pays to that address.
3. The launcher now asks you to save a backup. Follow Part 3.
4. After the backup is confirmed, mining starts. The window shows
   `Mining: N worker(s)`.

The mode is remembered. The next time, double-clicking **Start Mining** starts
mining again. To go back to node-only, double-click **Start Node** once.

If you want a fresh receive address at any time:

```
.\bin\cachecoin-cli.exe -rpcwallet=main getnewaddress
```

---

## Part 3 - Save your wallet backup (the most important step)

The launcher asks for this before mining. It saves two files to the folder you
choose:

- `cachecoin-main-wallet-<date>.bak` - the wallet file.
- `cachecoin-main-descriptors-<date>.json` - the keys, in text form.

Either file can restore your wallet on its own. Then the launcher asks you to
type a confirmation sentence. Until that sentence is saved, mining does not
start, including after a reboot.

Choose a USB stick or another disk - **not** the same disk as the program.
After saving, unplug the USB and keep it somewhere safe. Do not leave the only
copy in a cloud-synced folder.

If you receive more coins later, make a fresh backup. The easy way is to
double-click **My Keys and Backup** and choose option 1; it saves the same two
files and prints their sha256 values. The exact manual commands are in
`docs\BACKUP.txt`, which also contains the tested restore procedure.

---

## Part 4 - Print your private keys (advanced, optional)

You usually do not need this. The backup files from Part 3 are enough. Read the
warnings before you do it.

**WARNING: anyone who sees these keys can take your coins. There is no undo.**

The easy way: double-click **My Keys and Backup** and choose option 2. It warns
you, asks you to turn the internet off, asks you to type a confirmation phrase,
shows the keys, and clears the screen when you are done. It never writes the
keys to a log file.

The manual way:

1. Open PowerShell in the CacheCoin folder.
2. Run:

   ```
   .\bin\cachecoin-cli.exe -rpcwallet=main listdescriptors true
   ```

3. The output is JSON. The strings that start with `xprv...` are your private
   keys. The launcher's `descriptors.json` backup contains the same information.

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
  CacheCoin.cmd -Stop
  ```

- Stop it from starting at login:

  ```
  CacheCoin.cmd -DisableAutostart
  ```

- Turn the login start back on:

  ```
  CacheCoin.cmd -EnableAutostart
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
You are running Node only mode. Mining mode loads the wallet and shows the
balance. Run `CacheCoin.cmd -Mode mining` (it will ask for a backup first).

**"My clock is wrong. Does it stop mining?"**
No. The launcher only warns. If Windows time is wrong by more than 10 minutes,
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
- `docs\SECURITY.md` - security notes for this software.
