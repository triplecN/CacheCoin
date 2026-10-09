# Why CacheCoin uses Tor

CacheCoin is made to run from a home computer, so the program talks to the network only through Tor.
This page says plainly what that gives you and what it does not.

## Why Tor is on by default

A normal coin node tells every peer its IP address. That address points at your home and your
internet provider. CacheCoin's shipped settings use Tor only (`onlynet=onion`) and never fall back
to a direct connection, so your IP address is never told to the coin network. A fresh node-only
run with the default answers is outbound-only; when you mine (or if you turned incoming connections
on), the node publishes an onion address of its own (the Tor-only way of accepting incoming
connections) so other nodes can sync from it. An onion address is not your IP address.

## What Tor protects

- Your IP address and rough location are hidden from other nodes.
- Other nodes cannot easily tell which computer asked for which blocks.
- Your internet provider cannot read your coin traffic or see that you run a node.

## What Tor does NOT protect

- Amounts, addresses and the full history of every transaction are public on the blockchain forever.
- Tor is not a mixer: it does not hide where coins came from or make them anonymous.
- Anyone you pay sees the address you paid from, the amount and the time.
- If you use an exchange or a service that knows your name, that public link stays.
- Your wallet file, your recovery file and your password live on this computer. Tor does not protect them.

## Offline mode

Settings -> Offline mode runs the node with no network at all: no Tor, no peers. While it is on the
node cannot sync, mine or send; the wallet and the recovery file still work. It takes effect the next
time the node starts. The switch is in the CacheCoin App; the command-line launcher has no offline
mode. It is a good way to check a wallet in private.

## If Tor is blocked

Some networks block Tor. CacheCoin will not silently connect without it: when no Tor proxy can be
started the launcher stops instead of running the node, and nothing ever falls back to a direct
connection. If Tor starts but cannot connect yet, the node keeps running and retrying over Tor.
