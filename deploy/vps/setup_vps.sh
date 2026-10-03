#!/usr/bin/env bash
# ==============================================================================
# CacheCoin VPS seed / relay node installer
# Tested target: Ubuntu 24.04 LTS (should also work on Ubuntu 22.04 / Debian 12)
#
# What it does (idempotent, safe to re-run):
#   1. enables a 2 GB swap file if the VPS has little RAM and no swap
#   2. installs Tor and enables its control port with cookie authentication
#   3. creates the system user "cachecoin" (member of debian-tor) and checks that
#      it can read Tor's control cookie
#   4. installs /etc/cachecoin/cachecoin.conf (Tor-only, no mining, local RPC)
#   5. installs and starts the cachecoind systemd service
#   6. waits for the node's .onion address and prints it
#
# It opens no inbound ports: in Tor-only mode peers reach the node through Tor.
#
# Requirement: /usr/local/bin/cachecoind and /usr/local/bin/cachecoin-cli exist
# (build them on this VPS with scripts/build_linux.sh, or copy binaries built on
# the same Ubuntu release).
#
# Usage: sudo bash deploy/vps/setup_vps.sh
# ==============================================================================
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATADIR=/var/lib/cachecoind
CONF=/etc/cachecoin/cachecoin.conf

if [ "$(id -u)" -ne 0 ]; then
    echo "[!] Run as root: sudo bash $0"
    exit 1
fi
for bin in cachecoind cachecoin-cli; do
    if [ ! -x "/usr/local/bin/${bin}" ]; then
        echo "[!] /usr/local/bin/${bin} not found."
        echo "    Build it first: bash scripts/build_linux.sh"
        exit 1
    fi
done

echo "[1/6] Memory"
# RandomX (256 MiB), the UTXO cache, the mempool and Tor need about 1 GB together.
# Without swap the kernel kills cachecoind when a small VPS runs out of memory.
MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
if [ "${SWAP_KB}" -gt 0 ]; then
    echo "    swap is active ($((SWAP_KB / 1024)) MB)"
elif [ "${MEM_KB}" -ge 2500000 ]; then
    echo "    $((MEM_KB / 1024)) MB RAM, no swap needed"
else
    # Never follow or clobber a symlink, never delete a foreign file, and back
    # up fstab before appending.
    if [ ! -e /swapfile ] && [ ! -L /swapfile ] && [ "$(df --output=avail -k / | tail -n 1)" -gt 6000000 ]; then
        if fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null; then
            echo "    created /swapfile"
        else
            rm -f /swapfile
        fi
    fi
    if [ -f /swapfile ] && [ ! -L /swapfile ] && chmod 600 /swapfile && swapon /swapfile 2>/dev/null; then
        if ! grep -q '^/swapfile ' /etc/fstab; then
            cp -a /etc/fstab /etc/fstab.cachecoin-bak
            # Ensure we append on a fresh line, and boot without hanging if the
            # swapfile ever goes missing (nofail).
            [ -n "$(tail -c 1 /etc/fstab)" ] && printf '\n' >> /etc/fstab
            printf '%s\n' '/swapfile none swap sw,nofail 0 0' >> /etc/fstab
        fi
        echo "    enabled /swapfile as swap (also after reboots)"
    else
        echo "[!] Could not enable swap (too little disk space, or the VPS does not allow it)."
        echo "    With $((MEM_KB / 1024)) MB RAM, lower dbcache and maxmempool in ${CONF}."
    fi
fi

echo "[2/6] Installing Tor"
apt-get update -y
apt-get install -y tor python3
command -v python3 >/dev/null || { echo "[!] python3 is required (onion address parsing)."; exit 1; }

if ! grep -q "CacheCoin: lines appended" /etc/tor/torrc; then
    # Refuse a missing file or a symlink before root reads it (link-swap attack),
    # then stage through a root-owned copy (same reason as [4/6] below).
    [ -f "${HERE}/torrc.cachecoin" ] && [ ! -L "${HERE}/torrc.cachecoin" ] || { echo "[!] refusing to install from torrc.cachecoin"; exit 1; }
    TORRC_TMP="$(mktemp /root/torrc.cachecoin.XXXXXX)"
    install -m 0644 -o root -g root "${HERE}/torrc.cachecoin" "${TORRC_TMP}"
    { echo; cat "${TORRC_TMP}"; } >> /etc/tor/torrc
    rm -f "${TORRC_TMP}"
fi
systemctl enable tor
systemctl restart tor

echo "[3/6] Creating service user 'cachecoin'"
if ! id cachecoin >/dev/null 2>&1; then
    useradd --system --home-dir "${DATADIR}" --shell /usr/sbin/nologin cachecoin
fi
# Own the datadir explicitly: cachecoind must never inherit it from root or
# from a previous install with looser permissions.
install -d -m 0710 -o cachecoin -g cachecoin "${DATADIR}"
usermod -aG debian-tor cachecoin
# cachecoind creates its onion service through Tor's control port and needs to read
# the control cookie; Debian/Ubuntu make it readable for the debian-tor group.
COOKIE=/run/tor/control.authcookie
for _ in $(seq 1 30); do
    [ -e "${COOKIE}" ] && break
    sleep 1
done
if sudo -u cachecoin test -r "${COOKIE}"; then
    echo "    user cachecoin can read ${COOKIE}"
else
    echo "[!] User cachecoin cannot read ${COOKIE}: cachecoind will get no onion address."
    echo "    Check: ls -ld /run/tor ${COOKIE}   (group debian-tor, group-readable)"
fi

echo "[4/6] Installing ${CONF}"
# Install from a root-owned staging copy, not straight out of the (possibly
# user-writable) repo checkout: this script runs as root, so a tampered source
# file would otherwise become a root-read system config / unit file.
STAGE="$(mktemp -d /root/cachecoin-deploy.XXXXXX)"
chmod 0700 "${STAGE}"
for _f in cachecoin.conf cachecoind.service torrc.cachecoin; do
    # Never install from a missing file or a symlink (link-swap attack).
    [ -f "${HERE}/${_f}" ] && [ ! -L "${HERE}/${_f}" ] || { echo "[!] refusing to install from ${_f}"; exit 1; }
done
cp "${HERE}/cachecoin.conf" "${HERE}/cachecoind.service" "${HERE}/torrc.cachecoin" "${STAGE}/"
chown -R root:root "${STAGE}"
chmod 0644 "${STAGE}/cachecoin.conf" "${STAGE}/cachecoind.service" "${STAGE}/torrc.cachecoin"
install -d -m 0710 -o root -g cachecoin /etc/cachecoin
if [ -f "${CONF}" ]; then
    if cmp -s "${STAGE}/cachecoin.conf" "${CONF}"; then
        echo "    ${CONF} already exists, keeping it"
    else
        cp -a "${CONF}" "${CONF}.cachecoin-prev"
        echo "    ${CONF} exists and differs; left untouched, previous copy saved as ${CONF}.cachecoin-prev"
    fi
else
    install -m 0640 -o root -g cachecoin "${STAGE}/cachecoin.conf" "${CONF}"
fi

echo "[5/6] Installing and starting the cachecoind service"
install -m 0644 "${STAGE}/cachecoind.service" /etc/systemd/system/cachecoind.service
rm -rf "${STAGE}"
systemctl daemon-reload
systemctl enable cachecoind
systemctl restart cachecoind

echo "[6/6] Waiting for the onion address (Tor can take a minute)"
CLI=(sudo -u cachecoin /usr/local/bin/cachecoin-cli -datadir="${DATADIR}" -conf="${CONF}")
ONION=""
for _ in $(seq 1 60); do
    ONION="$(printf '%s' "$("${CLI[@]}" getnetworkinfo 2>/dev/null)" | python3 -c 'import sys,json; infos=json.load(sys.stdin).get("local_addresses",[]); print(next((a["address"] for a in infos if a.get("address","").endswith(".onion")), ""))' 2>/dev/null || true)"
    [ -n "${ONION}" ] && break
    sleep 5
done

echo
if [ -n "${ONION}" ]; then
    echo "=============================================================================="
    echo " CacheCoin seed node is running"
    echo "   onion address : ${ONION}:29333"
    echo "   use it in the home miner config:  connect=${ONION}:29333"
    echo "   others join with:                 addnode=${ONION}:29333"
    echo
    echo " BACK UP this file to keep the same onion address after a reinstall:"
    echo "   ${DATADIR}/onion_v3_private_key"
    echo "=============================================================================="
else
    echo "[!] No onion address yet. Check:  journalctl -u cachecoind -n 50"
    echo "    and:  journalctl -u cachecoind | grep -i tor | tail"
    exit 1
fi
echo
echo "Useful commands:"
echo "  sudo -u cachecoin cachecoin-cli -datadir=${DATADIR} -conf=${CONF} getblockchaininfo"
echo "  sudo -u cachecoin cachecoin-cli -datadir=${DATADIR} -conf=${CONF} getpeerinfo"
echo "  systemctl status cachecoind      journalctl -u cachecoind -f"
