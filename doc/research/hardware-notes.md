# CacheCoin hardware research notes

## Speculative notes: CPU → NPU → post-silicon (photonic, neuromorphic, quantum-resistant)

**Status:** Speculative research notes. None of this is implemented and none of it is part of CacheCoin consensus. The node implements RandomX v1 only, and nothing here implies a future hard fork: the chain changes only if independent node operators choose to run new software.  
**License:** MIT  

---

## 1. Summary

CacheCoin is a decentralized proof-of-work coin built around hardware that people already own. What it leans on is memory bandwidth, cache locality and energy efficiency.

Some networks are dominated by industrial ASIC farms, others by large proof-of-stake validator sets. CacheCoin starts from consumer computers instead, and these notes sketch where it could go if post-silicon hardware ever matures. The aim is broad access from consumer hardware, but in practice hash rate still varies a lot by machine and configuration (see README §1.6).

These notes are for future maintainers, node operators and researchers. They are research directions to evaluate, not consensus rules.

```
                            RESEARCH PHASES (NOT A PLAN)

  PHASE 1 (ACTIVE)              PHASE 2 (RESEARCH)            PHASE 3 (RESEARCH)
 ┌───────────────────────────┐ ┌───────────────────────────┐ ┌───────────────────────────┐
 │ CPU L3 memory-hard        │ │ NPU tensor arrays         │ │ Post-silicon frontier     │
 │                           │ │                           │ │                           │
 │ • Algorithm: RandomX v1   │ │ • Algorithm: integer GEMM │ │ • Silicon photonics (MZI) │
 │ • Medium: L3 CPU cache    │ │ • Medium: on-die NPU      │ │ • Neuromorphic (SNN/IMC)  │
 │ • Power: standard PC      │ │ • Power: example 5-15 W   │ │ • Post-quantum signatures │
 │ • Status: in the node     │ │ • Target: research only   │ │ • Power: unknown          │
 └───────────────────────────┘ └───────────────────────────┘ └───────────────────────────┘
```

---

## 2. Block header version allocation

What the node does today: every mined block uses the BIP9 block version `0x20000000` (Bitcoin Core's `ComputeBlockVersion`). Block versions below 4 are invalid from block 1 on, because BIP34/65/66 are active from the first block. So small version numbers such as `0x1` or `0x2` can never be used to mark hardware eras, and no such flags exist in the code.

A future upgrade would be coordinated the way Bitcoin coordinates upgrades. A new deployment claims one unused BIP9 bit under the `0x20000000` prefix, with its own start time, timeout and activation threshold. Classic BIP9 uses 1,916 of 2,016 blocks (95%), and a Taproot-style Speedy Trial variant with 1,815 of 2,016 (90%) is also possible. The eras below are ideas for such future deployments:

| Era | Hardware target | Status |
| :--- | :--- | :--- |
| Phase 1 | RandomX v1 on general-purpose CPUs | **Active** (the only proof of work in the code) |
| Phase 2 | Neural processing units (integer tensor math) | Research only, see §4 |
| Phase 3 | Post-silicon (photonic, neuromorphic, post-quantum signatures) | Research only, see §5 |

---

## 3. Phase 1: memory-hard CPU mining (genesis era, active)

### 3.1 Rationale

At genesis the priority is a low barrier to entry on hardware people already own. Anyone with an ordinary x86_64 or ARM64 laptop or desktop can verify and try to mine without special hardware. Performance and profitability vary, and neither is guaranteed. The field isn't perfectly level either: a miner holding the full ~2 GiB RandomX dataset in RAM is several times faster per core than the built-in light-mode miner, and the fixed RandomX key makes specialized hardware easier to build (see README §1.6).

### 3.2 Consensus mechanics

- **Algorithm:** RandomX, an asymmetric memory-hard CPU algorithm.
- **Target hardware:** general-purpose x86_64 and ARM64 CPU cores.
- **Memory:** each hash uses a 2 MiB scratchpad that fits in the CPU cache. Fast miners also keep the 2080 MiB RandomX dataset in RAM. Nodes verify in light mode with a 256 MiB cache, which is slower per hash but needs much less memory.
- **ASIC resistance:** RandomX runs randomized programs full of branching, 64-bit integer registers, floating-point math and memory-latency dependencies. That makes fixed-function ASICs uneconomic compared with CPUs, but not impossible. And because CacheCoin's RandomX key is fixed (Monero rotates its key), dedicated hardware is easier to specialize than it would be with a rotating key.

---

## 4. Phase 2: NPU tensor acceleration

### 4.1 Idle consumer silicon

Many consumer laptops now ship with an on-die neural processing unit (NPU). Apple has had one since the M1 in 2020. Intel and AMD added NPUs to their laptop chips in 2023, and Intel Lunar Lake, AMD Strix Point and Qualcomm Snapdragon X Elite followed in 2024. The 2024 flagship parts advertise roughly 40-50 TOPS, older Meteor Lake and Hawk Point chips are under 20, and Apple M3/M4 sit around 18-38 TOPS. On a typical desktop the NPU is mostly idle, waiting for background OS tasks.

CacheCoin sees this consumer AI silicon as a *possible* successor to pure CPU mining, if cross-vendor runtimes ever become stable and bit-exact enough for consensus. Today they are not.

### 4.2 Technical guidelines for future maintainers

If cross-vendor tensor runtimes (Microsoft DirectML, ONNX Runtime, or a unified Vulkan ML extension) ever work reliably on every operating system, a Phase 2 implementation would need to look like this:

1. **Math primitive and strict determinism**
   - The puzzle moves to general matrix-matrix multiplication (GEMM) over integer fields ($\mathbb{Z}/p\mathbb{Z}$ with 32/64-bit modular accumulation).
   - **Floating-point matrix math (FP16, BF16, FP32) is forbidden in the consensus engine.** Vendors round accumulations and order fused multiply-adds (FMA) differently, so floating-point results diverge across hardware, and divergence means an instant consensus split. Every NPU kernel must produce bit-exact integer results on every chip architecture. IEEE-754 only guarantees correctly rounded add, subtract, multiply, divide and square root. It does not pin down FMA contraction order, reductions or transcendental functions, so floating point is unfit for consensus even before vendor differences come in.
   - Pseudo-random memory lookups are interleaved with integer tensor dot products, with unified memory (LPDDR5X) feeding the NPU's systolic array directly.
2. **Thermal and energy envelope**
   - Mining should stay practical on thin fanless laptops, with a target of roughly 5-15 W for the mining workload. That needs real thermal testing, and nothing here is guaranteed.
3. **Activation**
   - Changing the proof of work is a hard fork. Every node has to run the new software, whatever miners signal. BIP9-style signaling (an unused version bit; classic BIP9 needs 1,916 of 2,016 blocks, 95%, and a Speedy Trial variant 1,815 of 2,016, 90%) can only coordinate the moment of the switch once node operators have upgraded.

---

## 5. Phase 3: post-silicon computing

### 5.1 Beyond classical silicon

Dennard scaling ended in the mid-2000s, and transistors are getting close to atomic dimensions. Classical electronic processors run into heat limits, quantum tunneling and power lost in interconnects ($I^2R$).

Phase 3 looks at three technologies.

#### 1. Silicon photonics and optical computing (OPU)

- **Mechanism:** passive matrix transforms computed by light interference in nanoscale Mach-Zehnder interferometers (MZIs) and optical waveguides.
- **Characteristics:** light propagates with low latency (about $c/n$ in a waveguide), but system power is dominated by lasers, DAC/ADC conversion and thermal phase shifters. Published demos reach about 1.5-9 TOPS/W at roughly 7-8 bit precision. Interesting, but not ready for consensus.
- **Parallelism:** wavelength-division multiplexing (WDM) lets several proof branches run at once on different wavelengths in a single optical channel.

#### 2. Neuromorphic computing and in-memory architectures (IMC)

- **Mechanism:** asynchronous, event-driven spiking neural networks (SNNs), and analog in-memory computing, which computes inside ReRAM/SRAM arrays instead of moving data over copper buses.
- **Characteristics:** lab demos run on under a watt, but analog in-memory compute is inherently noisy. The bit-exact determinism rule in §4.2 rules it out as a consensus candidate, so it stays a research topic.

#### 3. Post-quantum signatures (PQC)

- **Mechanism:** moving signature schemes to quantum-resistant standards such as ML-DSA (Dilithium, FIPS 204) before quantum attacks become practical. Hash-based signatures would mean SLH-DSA (SPHINCS+, FIPS 205), which is a separate standard.
- **Status:** ML-DSA is standardized and *believed* secure. The migration timeline follows NIST, which plans to finish around 2035. This is an inherited Bitcoin Core concern, not a CacheCoin plan: any signature migration would follow upstream.

---

*Released under the MIT License.*
