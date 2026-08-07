// Package hash is demo 4's CPU-bound workload: repeated SHA-256 over a fixed
// buffer.
//
// Three properties matter, and they are the reason this is hashing rather than a
// busy loop:
//
//   - It is real work. `for {}` invites the objection that no service does that;
//     hashing, compressing and parsing are what CPU-bound services actually
//     spend their time on, and the audience recognises it.
//   - It is deterministic. Each round hashes the previous digest back into the
//     buffer, so the output depends only on the round count and the seed — never
//     on the clock, the core count or the CPU quota. Every mode of this demo must
//     produce the identical checksum, which is what stops "faster" from quietly
//     meaning "did less work".
//   - It cannot be optimised away. The chained copy makes each round depend on
//     the last, so neither the compiler nor the CPU can skip or reorder them.
//
// There is no lock, no allocation in the hot loop, no channel and no I/O. When
// this demo gets slow, the workload is not the reason — which is precisely the
// point being made.
package hash

import (
	"crypto/sha256"
	"encoding/hex"
	"sync"
)

// BufferSize is the size of the buffer hashed on each round.
//
// 64 KiB is chosen to sit comfortably inside L2 on any machine that will run
// this, so the measurement is CPU-bound rather than memory-bandwidth-bound. A
// workload limited by cache misses would blur the quota effect this demo exists
// to show.
const BufferSize = 64 * 1024

// DefaultRounds costs about 150 ms of one core, measured on an Apple M3 Pro
// (linux/arm64 in a container, best of three):
//
//	rounds     200   400   800  1600  3200  6400
//	ms         8.0  10.0  18.8  37.8  97.2 164.1
//
// 150 ms is a deliberate choice: long enough that a 100 ms cgroup period cannot
// contain it — so a throttled request must be interrupted at least once — and
// short enough that a live load run finishes inside a sentence.
const DefaultRounds = 6000

// DefaultJobs and JobRounds size the POST /compute request that the
// before/investigate/after flow uses.
//
// One job costs ~73 ms of one core at JobRounds=3000, measured on an Apple M3
// Pro, so 16 jobs is ~1.17 core-seconds of arithmetic. Against the demo's two
// quotas that lands where the narrative needs it:
//
//	0.25 cores   ~4.7 s   twelve enforcement periods' worth of denied CPU
//	3 cores      ~0.4 s   the same work, finished as fast as the jobs allow
//
// 16 jobs rather than 2 is what makes the off-CPU capture worth doing: sixteen
// runnable goroutines against a quarter of a core means most of them are parked
// waiting for CPU at any instant, which is the time the flame graph is drawn
// from. A single-job request would spend its wait inside one stack and produce a
// flame graph with nothing to compare.
const (
	DefaultJobs = 16
	JobRounds   = 3000
)

// Result is the outcome of one unit of work.
type Result struct {
	// Rounds is how many hashing rounds were performed.
	Rounds int
	// Digest is the final hash, hex-encoded. Identical across every mode of this
	// demo for the same Rounds and seed; the equivalence test asserts it.
	Digest string
}

// Compute performs rounds of SHA-256 over a BufferSize buffer, feeding each
// digest back into the buffer.
//
// Deliberately allocates its own buffer per call rather than reusing a pooled
// one. That is one 64 KiB allocation against ~150 ms of hashing, so it is
// invisible in a CPU profile — and it keeps the function free of shared state,
// so concurrent callers cannot contend. Demo 3 is the demo about contention;
// this one must have none.
func Compute(rounds int, seed byte) Result {
	if rounds < 0 {
		rounds = 0
	}

	buf := make([]byte, BufferSize)
	for i := range buf {
		buf[i] = byte(i) ^ seed
	}

	var digest [32]byte
	for i := 0; i < rounds; i++ {
		digest = sha256.Sum256(buf)
		// Chain the digest back in. Without this the compiler is free to hoist
		// the whole loop, and every round would hash identical bytes.
		copy(buf, digest[:])
	}

	return Result{Rounds: rounds, Digest: hex.EncodeToString(digest[:])}
}

// ComputeJobs runs jobs concurrent Compute calls and waits for all of them.
//
// Each job gets its own seed, so the combined digest depends on the number of
// jobs and the round count and on nothing else — not the scheduler, not the core
// count, not the quota. That is what lets the before and after runs be compared:
// identical request, identical work, identical answer, only the quota differs.
//
// The combined digest is the hash of the per-job digests in job order, so a
// result that arrived out of order still folds to the same value.
func ComputeJobs(jobs, rounds int) Result {
	if jobs < 1 {
		jobs = 1
	}

	results := make([]Result, jobs)
	var wg sync.WaitGroup
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = Compute(rounds, byte(i))
		}(i)
	}
	wg.Wait()

	combined := sha256.New()
	for _, r := range results {
		_, _ = combined.Write([]byte(r.Digest))
	}
	return Result{
		Rounds: jobs * rounds,
		Digest: hex.EncodeToString(combined.Sum(nil)),
	}
}
