// CacheCoin: checks of the LWMA difficulty adjustment in src/pow.cpp on synthetic chains.
//
// Regtest does not retarget (fPowNoRetargeting), so the functional tests never exercise LWMA.
// This program calls the node's own GetNextWorkRequired() with the mainnet powLimit and block
// spacing and checks its behaviour. Build and run it with:
//     bash tests/lwma_check.sh <patched Bitcoin Core source directory>
#include <arith_uint256.h>
#include <chain.h>
#include <consensus/params.h>
#include <pow.h>
#include <uint256.h>

#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

namespace {

constexpr int N{60};            // LWMA window (blocks)
constexpr int64_t T0{1790360718}; // any start time (this is the genesis time)

int g_failures{0};

void Check(bool ok, const std::string& what)
{
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (!ok) ++g_failures;
}

arith_uint256 Target(uint32_t bits)
{
    arith_uint256 t;
    t.SetCompact(bits);
    return t;
}

double Ratio(uint32_t bits, const arith_uint256& base)
{
    return Target(bits).getdouble() / base.getdouble();
}

bool Near(double value, double expected) { return value > expected * 0.999 && value < expected * 1.001; }

// nBits the node requires for the block after a chain with these timestamps and nBits
// (entry h is block h; entry 0 plays the genesis block).
uint32_t Next(const std::vector<int64_t>& times, const std::vector<uint32_t>& bits, const Consensus::Params& params)
{
    std::vector<std::unique_ptr<CBlockIndex>> chain;
    for (size_t h = 0; h < times.size(); ++h) {
        chain.push_back(std::make_unique<CBlockIndex>());
        CBlockIndex& block = *chain.back();
        block.nHeight = static_cast<int>(h);
        block.nTime = static_cast<uint32_t>(times[h]);
        block.nBits = bits[h];
        block.pprev = h ? chain[h - 1].get() : nullptr;
    }
    return GetNextWorkRequired(chain.back().get(), nullptr, params);
}

std::vector<int64_t> Spaced(size_t blocks, int64_t spacing)
{
    std::vector<int64_t> times;
    for (size_t h = 0; h < blocks; ++h) times.push_back(T0 + static_cast<int64_t>(h) * spacing);
    return times;
}

// The timestamps the difficulty calculation actually uses: inside the window each block
// counts from the latest timestamp so far, at least one second later.
std::vector<int64_t> MonotonicWindow(std::vector<int64_t> times)
{
    for (size_t h = times.size() - N; h < times.size(); ++h) {
        if (times[h] <= times[h - 1]) times[h] = times[h - 1] + 1;
    }
    return times;
}

} // namespace

// Decode a runtime hex string into a uint256. The uint256(string_view) constructor is
// consteval, so it cannot take a string known only at runtime. The hex string is
// big-endian and uint256 stores little-endian, so the bytes are reversed on the way in.
static uint256 ParseHexToUint256(const char* hex)
{
    const std::string s{hex};
    std::vector<unsigned char> bytes;
    bytes.reserve(s.size() / 2);
    for (size_t i = 0; i + 1 < s.size(); i += 2) {
        bytes.push_back(static_cast<unsigned char>(std::stoul(s.substr(i, 2), nullptr, 16)));
    }
    // Pad on the left so the most-significant byte lands last in little-endian order.
    if (bytes.size() < 32) bytes.insert(bytes.begin(), 32 - bytes.size(), 0);
    std::reverse(bytes.begin(), bytes.end());
    return uint256{bytes};
}

int main(int argc, char** argv)
{
    if (argc != 3) {
        std::fprintf(stderr, "usage: %s <mainnet powLimit hex> <block spacing seconds>\n", argv[0]);
        return 2;
    }
    Consensus::Params params;
    // The uint256 constructor accepts the same hex string.
    params.powLimit = ParseHexToUint256(argv[1]);
    params.nPowTargetSpacing = std::stoll(argv[2]);
    params.fPowNoRetargeting = false;
    const int64_t T{params.nPowTargetSpacing};
    const arith_uint256 pow_limit{UintToArith256(params.powLimit)};
    const uint32_t limit_bits{pow_limit.GetCompact()};
    std::printf("powLimit %s (nBits %08x), spacing %lld s, window %d blocks\n",
                params.powLimit.GetHex().c_str(), limit_bits, static_cast<long long>(T), N);

    // A difficulty well above the minimum (target = powLimit / 2^20).
    const uint32_t base_bits{arith_uint256{pow_limit >> 20}.GetCompact()};
    const arith_uint256 base{Target(base_bits)};
    const size_t len{2 * N + 1}; // blocks 0..120: the window is full

    // 1. The first blocks are mined at the minimum difficulty.
    for (size_t blocks : {size_t{1}, size_t{2}, size_t{N}}) {
        Check(Next(Spaced(blocks, T), std::vector<uint32_t>(blocks, limit_bits), params) == limit_bits,
              "tip height " + std::to_string(blocks - 1) + ": next block uses powLimit");
    }

    // 2. Blocks exactly on target keep the difficulty.
    Check(Next(Spaced(len, T), std::vector<uint32_t>(len, base_bits), params) == base_bits,
          "blocks every T keep the difficulty unchanged");

    // 3. Faster blocks raise the difficulty, slower blocks lower it, in proportion.
    const std::vector<uint32_t> base_chain(len, base_bits);
    Check(Near(Ratio(Next(Spaced(len, T / 2), base_chain, params), base), 0.5), "blocks every T/2 halve the target");
    Check(Near(Ratio(Next(Spaced(len, 2 * T), base_chain, params), base), 2.0), "blocks every 2T double the target");

    // 4. One very long solve time counts as 6T, never more.
    {
        auto capped = Spaced(len, T);
        capped.back() = capped[len - 2] + 6 * T;
        auto huge = Spaced(len, T);
        huge.back() = huge[len - 2] + 3600;
        Check(Next(capped, base_chain, params) == Next(huge, base_chain, params), "a 1-hour solve time counts as 6T");
    }

    // 5. The minimum weighted solve time (k/10) limits a difficulty rise to 10x per block.
    {
        std::vector<int64_t> same(len, T0);
        Check(Near(Ratio(Next(same, base_chain, params), base), 0.1),
              "a window with identical timestamps raises the difficulty 10x at most");
    }

    // 6. A slow chain at minimum difficulty stays at powLimit.
    Check(Next(Spaced(len, 10 * T), std::vector<uint32_t>(len, limit_bits), params) == limit_bits,
          "slow blocks never make the target easier than powLimit");

    // 7. A block timestamped before its predecessor counts as 1 second after the latest
    //    timestamp: the result equals that of the chain with those timestamps made monotonic.
    {
        auto times = Spaced(len, T);
        times[len - 30] = times[len - 31] - 500; // inside the window
        times[len - 1] = times[len - 2] - 300;   // the tip itself
        Check(Next(times, base_chain, params) == Next(MonotonicWindow(times), base_chain, params),
              "out-of-order timestamps are counted from the latest earlier timestamp");
    }

    // 8. Random chains: the monotonic rule holds, and the result is always a valid target.
    {
        std::mt19937_64 rng{20260927};
        std::uniform_int_distribution<int64_t> gap{-10 * T, 15 * T};
        std::uniform_int_distribution<int> shift{0, 30};
        int monotonic_ok{0}, range_ok{0};
        const int rounds{500};
        for (int r = 0; r < rounds; ++r) {
            std::vector<int64_t> times{T0};
            std::vector<uint32_t> bits{limit_bits};
            for (size_t h = 1; h < len; ++h) {
                times.push_back(times.back() + gap(rng));
                bits.push_back(arith_uint256{pow_limit >> shift(rng)}.GetCompact());
            }
            const uint32_t next{Next(times, bits, params)};
            if (next == Next(MonotonicWindow(times), bits, params)) ++monotonic_ok;
            const arith_uint256 target{Target(next)};
            if (target > 0 && target <= pow_limit && CheckProofOfWorkRange(next, params)) ++range_ok;
        }
        Check(monotonic_ok == rounds, "500 random chains: result equals the monotonic-timestamp chain");
        Check(range_ok == rounds, "500 random chains: result is a non-zero target no easier than powLimit");
    }

    // 9. Hash-rate collapse and recovery. Blocks are spaced by the fixed hash rate
    //    and the current target (solve time = T * base / (target * hashrate)), which
    //    is what a real chain does: when the hash rate drops to 1/10, the target has
    //    to grow 10x for blocks to come every T again. The difficulty must never go
    //    the wrong way, must settle at the 10x easier target, stay a valid target,
    //    and return to the starting difficulty when the hash rate comes back.
    {
        std::vector<int64_t> times{Spaced(len, T)};
        std::vector<uint32_t> bits(len, base_bits);
        uint32_t cur{Next(times, bits, params)};
        const auto spacing_for = [&](uint32_t nbits, double hashrate) {
            const double s{static_cast<double>(T) * base.getdouble() /
                           (Target(nbits).getdouble() * hashrate)};
            return std::max<int64_t>(1, static_cast<int64_t>(s));
        };
        const auto run = [&](double hashrate, double& min_ratio, double& max_ratio) {
            for (int i = 0; i < 4 * N; ++i) {
                times.push_back(times.back() + spacing_for(cur, hashrate));
                bits.push_back(cur);
                cur = Next(times, bits, params);
                const double ratio{Ratio(cur, base)};
                if (ratio < min_ratio) min_ratio = ratio;
                if (ratio > max_ratio) max_ratio = ratio;
            }
        };

        double min_ratio{1e9}, max_ratio{0};
        run(0.1, min_ratio, max_ratio);
        std::printf("  [collapse] target after a 90%% hash-rate drop: %.2fx (range %.2f..%.2f)\n",
                    Ratio(cur, base), min_ratio, max_ratio);
        Check(min_ratio > 0.99, "a hash-rate drop never makes the difficulty harder");
        Check(Target(cur) <= pow_limit && CheckProofOfWorkRange(cur, params),
              "the collapsed target is a valid proof-of-work target");
        Check(Ratio(cur, base) > 8.0 && Ratio(cur, base) < 12.0,
              "the difficulty settles at the 10x easier target the hash rate needs");
        Check(max_ratio < 15.0, "the collapsed target does not overshoot the 10x by more than the clamp");

        min_ratio = 1e9;
        max_ratio = 0;
        run(1.0, min_ratio, max_ratio);
        std::printf("  [recovery] target after the hash rate returns: %.2fx (range %.2f..%.2f)\n",
                    Ratio(cur, base), min_ratio, max_ratio);
        Check(max_ratio < 12.0, "the recovery never drifts back toward the collapsed target");
        Check(min_ratio > 0.8, "the recovery never makes the difficulty harder than the hash rate needs");
        Check(Ratio(cur, base) > 0.9 && Ratio(cur, base) < 1.1,
              "the difficulty returns to where it started when the hash rate does");
    }

    // 10. Pulse mining (profit-switching pools): the hash rate alternates between
    //     10x and 1/10x every 15 blocks, for 40 cycles, with solve times derived
    //     from the current target and hash rate. A difficulty filter with resonance
    //     would show growing swings; the swing must stay bounded and the target
    //     must stay valid.
    {
        std::vector<int64_t> times{Spaced(len, T)};
        std::vector<uint32_t> bits(len, base_bits);
        uint32_t cur{Next(times, bits, params)};
        const auto spacing_for = [&](uint32_t nbits, double hashrate) {
            const double s{static_cast<double>(T) * base.getdouble() /
                           (Target(nbits).getdouble() * hashrate)};
            return std::max<int64_t>(1, static_cast<int64_t>(s));
        };
        constexpr int PULSE{15};
        constexpr int CYCLES{40};
        std::vector<double> peaks;  // target ratio at the end of every fast phase
        double lo{1e9}, hi{0};
        for (int b = 0; b < CYCLES * 2 * PULSE; ++b) {
            const bool fast{(b / PULSE) % 2 == 0};
            times.push_back(times.back() + spacing_for(cur, fast ? 10.0 : 0.1));
            bits.push_back(cur);
            cur = Next(times, bits, params);
            const double r{Ratio(cur, base)};
            if (r < lo) lo = r;
            if (r > hi) hi = r;
            if (b % (2 * PULSE) == PULSE - 1) peaks.push_back(r);
        }
        const auto swing = [&](size_t from, size_t to) {
            double a{peaks[from]}, b{peaks[from]};
            for (size_t i = from; i < to; ++i) { a = std::min(a, peaks[i]); b = std::max(b, peaks[i]); }
            return b / a;
        };
        const size_t half{peaks.size() / 2};
        const double early{swing(0, half)}, late{swing(half, peaks.size())};
        std::printf("  [pulse] target range %.2f..%.2f, swing early %.2fx late %.2fx\n", lo, hi, early, late);
        Check(Target(cur) <= pow_limit && CheckProofOfWorkRange(cur, params),
              "pulse mining: the target stays a valid proof-of-work target");
        Check(lo > 0.0 && hi < 100.0, "pulse mining: the target stays within two orders of magnitude");
        Check(late <= early * 1.5, "pulse mining: the swing does not grow (no harmonic resonance)");
    }

    std::printf("%s: %d failure(s)\n", g_failures ? "LWMA CHECK FAILED" : "LWMA CHECK OK", g_failures);
    return g_failures ? 1 : 0;
}
