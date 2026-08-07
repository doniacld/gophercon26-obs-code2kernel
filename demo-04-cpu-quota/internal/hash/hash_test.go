package hash

import (
	"runtime"
	"sync"
	"testing"
)

// TestDeterministic is the assertion the whole demo rests on: the workload's
// result depends only on its inputs.
//
// Demo 4 compares three CPU quotas and claims the service does the same work in
// all three. If Compute could vary with the clock, the core count or the
// scheduler, "the throttled run was slower" would be unfalsifiable — it might
// simply have done more. This test is what makes the comparison mean something.
func TestDeterministic(t *testing.T) {
	first := Compute(64, 0)
	for i := 0; i < 8; i++ {
		got := Compute(64, 0)
		if got.Digest != first.Digest {
			t.Fatalf("run %d: digest %s, want %s — the workload is not deterministic",
				i, got.Digest, first.Digest)
		}
	}
}

// TestIndependentOfGOMAXPROCS is the specific equivalence the demo needs.
//
// The three modes differ only in CPU quota, and on Go 1.25+ the quota changes
// GOMAXPROCS — so the digest must survive a GOMAXPROCS change or the modes are
// not comparable. This simulates what the quota does to the runtime.
func TestIndependentOfGOMAXPROCS(t *testing.T) {
	original := runtime.GOMAXPROCS(0)
	defer runtime.GOMAXPROCS(original)

	want := Compute(64, 0).Digest
	for _, procs := range []int{1, 2, 4} {
		runtime.GOMAXPROCS(procs)
		if got := Compute(64, 0).Digest; got != want {
			t.Errorf("GOMAXPROCS=%d: digest %s, want %s", procs, got, want)
		}
	}
}

// TestConcurrentCallersAgree checks that Compute shares no state.
//
// The service can run -shards goroutines per request and serves concurrent
// requests, so a hidden shared buffer would corrupt results under load — and
// under load is exactly when nobody is checking. Run with -race.
func TestConcurrentCallersAgree(t *testing.T) {
	want := Compute(32, 7).Digest

	var wg sync.WaitGroup
	digests := make([]string, 16)
	for i := range digests {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			digests[i] = Compute(32, 7).Digest
		}(i)
	}
	wg.Wait()

	for i, got := range digests {
		if got != want {
			t.Errorf("goroutine %d: digest %s, want %s", i, got, want)
		}
	}
}

// TestSeedChangesDigest guards the chaining. If the copy back into the buffer
// were removed, every round would hash the same bytes and the seed would still
// change the result — but TestRoundsChangeDigest below would fail. Together the
// two pin down that the loop actually iterates.
func TestSeedChangesDigest(t *testing.T) {
	a := Compute(16, 0).Digest
	b := Compute(16, 1).Digest
	if a == b {
		t.Errorf("seeds 0 and 1 produced the same digest %s", a)
	}
}

func TestRoundsChangeDigest(t *testing.T) {
	a := Compute(16, 0).Digest
	b := Compute(17, 0).Digest
	if a == b {
		t.Errorf("16 and 17 rounds produced the same digest %s — the chain is broken", a)
	}
}

func TestZeroRounds(t *testing.T) {
	r := Compute(0, 0)
	if r.Rounds != 0 {
		t.Errorf("Rounds = %d, want 0", r.Rounds)
	}
	// A digest of all zeroes, hex-encoded: no rounds ran, so nothing was hashed.
	if want := "0000000000000000000000000000000000000000000000000000000000000000"; r.Digest != want {
		t.Errorf("Digest = %s, want %s", r.Digest, want)
	}
}

func TestNegativeRoundsClamped(t *testing.T) {
	if r := Compute(-5, 0); r.Rounds != 0 {
		t.Errorf("Rounds = %d for a negative input, want 0", r.Rounds)
	}
}

// TestComputeJobsDeterministic is the equivalence the before/after comparison
// rests on: POST /compute {"jobs":16} must produce the same digest under a
// throttled quota and an unthrottled one. Sixteen goroutines finishing in a
// different order must still fold to the same value, or "the fix was faster"
// could mean "the fix did less".
func TestComputeJobsDeterministic(t *testing.T) {
	want := ComputeJobs(16, 8).Digest
	for i := 0; i < 8; i++ {
		if got := ComputeJobs(16, 8).Digest; got != want {
			t.Fatalf("run %d: digest %s, want %s", i, got, want)
		}
	}
}

// TestComputeJobsIndependentOfGOMAXPROCS simulates what the CPU quota does to
// the runtime. The digest must not move when the scheduler has fewer processors
// to work with.
func TestComputeJobsIndependentOfGOMAXPROCS(t *testing.T) {
	original := runtime.GOMAXPROCS(0)
	defer runtime.GOMAXPROCS(original)

	want := ComputeJobs(16, 8).Digest
	for _, procs := range []int{1, 2, 4} {
		runtime.GOMAXPROCS(procs)
		if got := ComputeJobs(16, 8).Digest; got != want {
			t.Errorf("GOMAXPROCS=%d: digest %s, want %s", procs, got, want)
		}
	}
}

// TestComputeJobsCountChangesDigest guards against a combined digest that
// ignores some of its jobs — which would make the equivalence test above pass
// for the wrong reason.
func TestComputeJobsCountChangesDigest(t *testing.T) {
	if a, b := ComputeJobs(4, 8).Digest, ComputeJobs(5, 8).Digest; a == b {
		t.Errorf("4 and 5 jobs produced the same digest %s", a)
	}
}

func TestComputeJobsClampsBelowOne(t *testing.T) {
	want := ComputeJobs(1, 8).Digest
	for _, jobs := range []int{0, -3} {
		if got := ComputeJobs(jobs, 8).Digest; got != want {
			t.Errorf("jobs=%d: digest %s, want the 1-job digest %s", jobs, got, want)
		}
	}
}

// BenchmarkCompute is the offline fallback. No ports, no Docker, no cgroup: it
// establishes the per-request CPU cost on this machine, which is the number the
// quota has to be large enough to serve.
func BenchmarkCompute(b *testing.B) {
	for b.Loop() {
		Compute(DefaultRounds, 0)
	}
}

// BenchmarkComputeJob is the number the demo's arithmetic is quoted in: one job
// of the POST /compute request, at the rounds that request actually uses.
//
// BenchmarkCompute above measures DefaultRounds, which is the /compute GET
// endpoint's unit and roughly twice as long. Quoting that one as "per job" is how
// the talk track ends up contradicting the screen.
func BenchmarkComputeJob(b *testing.B) {
	for b.Loop() {
		Compute(JobRounds, 0)
	}
}

// BenchmarkComputeJobs is the whole request, on as many cores as the machine
// will give it. ns/op here is wall clock rather than CPU time — 16 jobs run
// concurrently — so it is the floor a correct quota permits, not the demand.
// Multiply BenchmarkComputeJob by DefaultJobs for the demand.
func BenchmarkComputeJobs(b *testing.B) {
	for b.Loop() {
		ComputeJobs(DefaultJobs, JobRounds)
	}
}
