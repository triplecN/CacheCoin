#!/usr/bin/env python3
"""
Shunko Protocol: design-study model (not part of the node).

A spy runs listening nodes and guesses that the first node it hears a transaction from is the
sender ("first announcer" heuristic). The simulation compares:

  * normal broadcast: the sender's own node announces the transaction to its peers;
  * Shunko: the sender hands it to random nodes over one-shot connections and never announces it.

It is an abstract model (random graph, fixed delays) that demonstrates the design
effect; it is not an anonymity measurement. Standard library only.

Usage: python shunko_node_mesh.py [runs]
"""

import random
import sys

NODES = 200
PEERS_PER_NODE = 8
SPY_FRACTION = 0.10
HANDOVER_TARGETS = 2


def build_network(rng):
    peers = {n: set() for n in range(NODES)}
    for n in range(NODES):
        while len(peers[n]) < PEERS_PER_NODE:
            m = rng.randrange(NODES)
            if m != n:
                peers[n].add(m)
                peers[m].add(n)
    return peers


def spread(peers, starters, rng):
    """Flood from `starters`; return the time each node first hears the transaction and from whom."""
    heard = {s: (0.0, None) for s in starters}
    frontier = list(starters)
    while frontier:
        nxt = []
        for n in frontier:
            t0 = heard[n][0]
            for m in peers[n]:
                t = t0 + rng.uniform(0.5, 1.5)  # random relay delay
                if m not in heard or t < heard[m][0]:
                    heard[m] = (t, n)
                    nxt.append(m)
        frontier = nxt
    return heard


def spy_guess(heard, spies):
    """The spy blames the node it heard the transaction from first."""
    first = min((heard[s] for s in spies if s in heard and heard[s][1] is not None), default=None)
    return first[1] if first else None


def run(runs=500, seed=1):
    rng = random.Random(seed)
    caught_normal = caught_shunko = 0
    for _ in range(runs):
        peers = build_network(rng)
        spies = set(rng.sample(range(NODES), int(NODES * SPY_FRACTION)))
        sender = rng.choice([n for n in range(NODES) if n not in spies])

        # Normal broadcast: the sender's node announces to its own peers.
        if spy_guess(spread(peers, [sender], rng), spies) == sender:
            caught_normal += 1

        # Shunko: random nodes (reached over one-shot Tor circuits) announce it instead.
        starters = rng.sample([n for n in range(NODES) if n != sender], HANDOVER_TARGETS)
        if spy_guess(spread(peers, starters, rng), spies) == sender:
            caught_shunko += 1

    print(f"{runs} runs, {NODES} nodes, {int(SPY_FRACTION * 100)}% spy nodes")
    print(f"  spy identifies the sender, normal broadcast : {caught_normal / runs:6.1%}")
    print(f"  spy identifies the sender, Shunko hand-over : {caught_shunko / runs:6.1%}")
    print("The ledger is public in both cases: amounts and addresses stay visible.")


if __name__ == "__main__":
    run(int(sys.argv[1]) if len(sys.argv) > 1 else 500)
