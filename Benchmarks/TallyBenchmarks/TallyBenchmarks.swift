import Foundation
import Tally

@main
struct TallyBenchmarks {
    static func main() {
        let samples = 50
        let opsPerSample = 1000
        var results: [BenchmarkResult] = []
        let clock = ContinuousClock()

        // --- shouldAllow (fresh peer, under limit) ---
        do {
            var timings: [Double] = []
            for s in 0..<samples {
                let tally = Tally()
                var peers: [PeerID] = []
                for i in 0..<opsPerSample {
                    peers.append(PeerID(publicKey: "fresh-\(s)-\(i)"))
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    _ = tally.shouldAllow(peer: peers[i])
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "shouldAllow (fresh)", iterations: opsPerSample, samples: timings))
        }

        // --- shouldAllow (known peer) ---
        do {
            let tally = Tally()
            let peer = PeerID(publicKey: "known")
            tally.recordReceived(peer: peer, bytes: 1000)
            tally.recordSent(peer: peer, bytes: 500)
            for _ in 0..<5 { tally.recordSuccess(peer: peer) }
            tally.recordLatency(peer: peer, microseconds: 5000)
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = tally.shouldAllow(peer: peer)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "shouldAllow (known)", iterations: opsPerSample, samples: timings))
        }

        // --- reputation lookup ---
        do {
            let tally = Tally()
            let peer = PeerID(publicKey: "rep-peer")
            tally.recordSent(peer: peer, bytes: 5000)
            tally.recordReceived(peer: peer, bytes: 2500)
            for _ in 0..<10 { tally.recordSuccess(peer: peer) }
            tally.recordLatency(peer: peer, microseconds: 10000)
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = tally.reputation(for: peer)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "reputation", iterations: opsPerSample, samples: timings))
        }

        // --- recordSent ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let tally = Tally()
                let peer = PeerID(publicKey: "sender")
                let start = clock.now
                for _ in 0..<opsPerSample {
                    tally.recordSent(peer: peer, bytes: 1024)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "recordSent", iterations: opsPerSample, samples: timings))
        }

        // --- recordLatency ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let tally = Tally()
                let peer = PeerID(publicKey: "lat-peer")
                tally.recordRequest(peer: peer)
                let start = clock.now
                for _ in 0..<opsPerSample {
                    tally.recordLatency(peer: peer, microseconds: 5000)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "recordLatency", iterations: opsPerSample, samples: timings))
        }

        // --- mixed (80% check / 20% record) ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let tally = Tally()
                var peers: [PeerID] = []
                for i in 0..<50 {
                    let p = PeerID(publicKey: "mix-\(i)")
                    peers.append(p)
                    tally.recordSent(peer: p, bytes: 500)
                    tally.recordReceived(peer: p, bytes: 300)
                    tally.recordSuccess(peer: p)
                    tally.recordLatency(peer: p, microseconds: 10000)
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    let p = peers[i % peers.count]
                    if i % 5 == 0 {
                        tally.recordSent(peer: p, bytes: 1024)
                    } else {
                        _ = tally.shouldAllow(peer: p)
                    }
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "mixed 80c/20w", iterations: opsPerSample, samples: timings))
        }

        printReport(results)
    }
}
