package work

import (
	"context"
	"runtime"
	"sync"
	"testing"
	"time"
)

// TestLockedModeSerializesTheWork asserts the bug is actually present: wall clock
// is close to the sum of the task durations, however many cores exist, and never
// more than one task is inside expensiveWork at a time.
//
// If this fails on the venue machine the demo will not show what the talk says it
// shows — so it is worth running before the talk, not just in CI.
func TestLockedModeSerializesTheWork(t *testing.T) {
	if runtime.GOMAXPROCS(0) < 2 {
		t.Skip("needs at least 2 processors to distinguish serial from parallel")
	}
	tasks := Tasks(8, 20*time.Millisecond)
	s := NewStore()

	b := s.RunLocked(context.Background(), tasks)

	// PeakWorking is the direct measurement: how many tasks were ever inside
	// expensiveWork simultaneously. Exactly 1 is the bug, stated without
	// reference to the clock — so a slow CI machine cannot make this pass or fail
	// for the wrong reason.
	if b.PeakWorking != 1 {
		t.Errorf("PeakWorking = %d, want exactly 1 — the mutex should admit one task at a time", b.PeakWorking)
	}
	if got := b.Speedup(); got > 1.5 {
		t.Errorf("Speedup() = %.2f, want ~1.0 — the mutex should have serialized the work", got)
	}
	if b.Wall < b.CPUTime*8/10 {
		t.Errorf("Wall = %v, want close to the %v sum of task durations", b.Wall, b.CPUTime)
	}
	assertAllTasksRan(t, b, len(tasks))
}

// TestUnlockedModeUsesTheCores asserts the fix works: several tasks compute at once
// and the wall clock is a fraction of the total CPU time.
func TestUnlockedModeUsesTheCores(t *testing.T) {
	procs := runtime.GOMAXPROCS(0)
	if procs < 4 {
		t.Skip("needs at least 4 processors for a meaningful speedup assertion")
	}
	tasks := Tasks(16, 20*time.Millisecond)
	s := NewStore()

	b := s.RunUnlocked(context.Background(), tasks)

	if b.PeakWorking < 2 {
		t.Errorf("PeakWorking = %d on a %d-processor machine, want at least 2", b.PeakWorking, procs)
	}
	// At least a factor of 2, not the full GOMAXPROCS. CI machines are shared and
	// a strict assertion would be flaky — but 2× is far outside anything serial
	// execution can produce.
	if got := b.Speedup(); got < 2 {
		t.Errorf("Speedup() = %.2f on %d processors, want at least 2.0", got, procs)
	}
	assertAllTasksRan(t, b, len(tasks))
}

// TestUnlockedModeBeatsLocked is the comparison the demo makes on stage, asserted.
func TestUnlockedModeBeatsLocked(t *testing.T) {
	if runtime.GOMAXPROCS(0) < 4 {
		t.Skip("needs at least 4 processors")
	}
	tasks := Tasks(16, 15*time.Millisecond)

	locked := NewStore().RunLocked(context.Background(), tasks)
	unlocked := NewStore().RunUnlocked(context.Background(), tasks)

	if unlocked.Wall >= locked.Wall {
		t.Errorf("unlocked wall %v is not better than locked wall %v", unlocked.Wall, locked.Wall)
	}
	// The contention is the mechanism, so assert on it directly rather than only
	// on the outcome. Locked mode's tasks queue behind each other; unlocked mode's
	// barely wait at all.
	if unlocked.LockWait >= locked.LockWait/4 {
		t.Errorf("unlocked lock wait %v should be far below locked's %v", unlocked.LockWait, locked.LockWait)
	}
	t.Logf("locked %v (speedup %.2f, lock wait %v) vs unlocked %v (speedup %.2f, lock wait %v)",
		locked.Wall.Round(time.Millisecond), locked.Speedup(), locked.LockWait.Round(time.Millisecond),
		unlocked.Wall.Round(time.Millisecond), unlocked.Speedup(), unlocked.LockWait.Round(time.Millisecond))
}

// TestBothModesProduceTheSameChecksums confirms the fix did not change what is
// computed.
//
// It also caught a real bug during development: expensiveWork originally
// accumulated across the whole timed loop, so its result depended on how many
// iterations fit in the duration, and therefore on how busy the machine was. A
// "faster" version that quietly computes something else is the failure mode every
// optimisation demo has to rule out.
func TestBothModesProduceTheSameChecksums(t *testing.T) {
	tasks := Tasks(6, 5*time.Millisecond)

	locked := NewStore().RunLocked(context.Background(), tasks)
	unlocked := NewStore().RunUnlocked(context.Background(), tasks)

	for i := range tasks {
		if locked.Results[i].ID != unlocked.Results[i].ID {
			t.Errorf("slot %d: locked id=%d, unlocked id=%d — results are misordered",
				i, locked.Results[i].ID, unlocked.Results[i].ID)
		}
		if locked.Results[i].Checksum != unlocked.Results[i].Checksum {
			t.Errorf("slot %d: checksums differ (%d vs %d)",
				i, locked.Results[i].Checksum, unlocked.Results[i].Checksum)
		}
	}
}

// TestChecksumsAreDistinctPerTask stops the equivalence test above from passing
// vacuously: if every task returned the same value, "the checksums match" would
// prove nothing about results landing in the right slots.
func TestChecksumsAreDistinctPerTask(t *testing.T) {
	b := NewStore().RunUnlocked(context.Background(), Tasks(8, 2*time.Millisecond))

	seen := make(map[uint64]int, len(b.Results))
	for _, r := range b.Results {
		if prev, dup := seen[r.Checksum]; dup {
			t.Errorf("tasks %d and %d produced the same checksum %d — the work does not depend on the task",
				prev, r.ID, r.Checksum)
		}
		seen[r.Checksum] = r.ID
	}
}

// TestChecksumIsIndependentOfDuration: the same task computes the same value
// whether it ran for 2ms or 20ms. Without this property every timing difference
// between the modes would also be a correctness difference.
func TestChecksumIsIndependentOfDuration(t *testing.T) {
	short := NewStore().RunUnlocked(context.Background(), Tasks(4, 2*time.Millisecond))
	long := NewStore().RunUnlocked(context.Background(), Tasks(4, 20*time.Millisecond))

	for i := range short.Results {
		if short.Results[i].Checksum != long.Results[i].Checksum {
			t.Errorf("task %d: checksum changed with duration (%d at 2ms vs %d at 20ms) — "+
				"the result depends on how fast the machine is",
				i, short.Results[i].Checksum, long.Results[i].Checksum)
		}
	}
}

// TestStoreHoldsTheLatestResultPerItem is the reason the mutex exists. Run under
// -race, this is what would fail if the fix had "optimised" the lock away.
func TestStoreHoldsTheLatestResultPerItem(t *testing.T) {
	s := NewStore()
	tasks := Tasks(8, 2*time.Millisecond)

	// Four concurrent requests over the same eight item indices: every request
	// writes every key, so the map is contended from several directions at once.
	var wg sync.WaitGroup
	for i := range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if i%2 == 0 {
				s.RunLocked(context.Background(), tasks)
			} else {
				s.RunUnlocked(context.Background(), tasks)
			}
		}()
	}
	wg.Wait()

	st := s.Stats()
	if st.StoredKeys != len(tasks) {
		t.Errorf("StoredKeys = %d, want %d — the store should hold one entry per item index",
			st.StoredKeys, len(tasks))
	}
	if st.Writes != int64(4*len(tasks)) {
		t.Errorf("Writes = %d, want %d — every task should have stored its result",
			st.Writes, 4*len(tasks))
	}
	if st.Requests != 4 {
		t.Errorf("Requests = %d, want 4", st.Requests)
	}
	if st.Working != 0 {
		t.Errorf("Working = %d after all batches returned, want 0", st.Working)
	}
}

// TestCancellationIsObserved documents an uncomfortable property rather than a
// clean one: a sync.Mutex has no context-aware Lock, so a goroutine already
// queued on the mutex cannot be cancelled. The most a cancelled request can do is
// release the lock immediately once it finally acquires it.
//
// So this asserts the batch is *marked* cancelled and that no partial results
// were stored — not that it returned promptly, because in locked mode it cannot.
// That limitation is the point, and the README says so.
func TestCancellationIsObserved(t *testing.T) {
	s := NewStore()
	tasks := Tasks(8, 20*time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled before the batch starts

	b := s.RunLocked(ctx, tasks)

	if !b.Cancelled {
		t.Error("Cancelled = false for a batch run with an already-cancelled context")
	}
	if st := s.Stats(); st.Writes != 0 {
		t.Errorf("store writes = %d for a cancelled batch, want 0", st.Writes)
	}
}

func TestResetClearsTheCounters(t *testing.T) {
	s := NewStore()
	s.RunUnlocked(context.Background(), Tasks(4, 2*time.Millisecond))

	if st := s.Stats(); st.Tasks == 0 || st.StoredKeys == 0 {
		t.Fatalf("expected counters to be non-zero before reset, got %+v", st)
	}

	s.Reset()

	st := s.Stats()
	if st.Requests != 0 || st.Tasks != 0 || st.StoredKeys != 0 ||
		st.Writes != 0 || st.PeakWorking != 0 || st.LockWaitMS != 0 {
		t.Errorf("Reset() left state behind: %+v", st)
	}
}

func TestRunRejectsUnknownMode(t *testing.T) {
	if _, err := NewStore().Run(context.Background(), "sideways", Tasks(1, time.Millisecond)); err == nil {
		t.Error("Run with an unknown mode should return an error")
	}
}

func assertAllTasksRan(t *testing.T, b *Batch, n int) {
	t.Helper()
	if len(b.Results) != n {
		t.Fatalf("len(Results) = %d, want %d", len(b.Results), n)
	}
	for i, r := range b.Results {
		if r.Checksum == 0 {
			t.Errorf("task at slot %d produced no checksum; it did not run", i)
		}
		if r.Finished <= r.Started {
			t.Errorf("task %d finished (%v) before it started (%v)", r.ID, r.Finished, r.Started)
		}
	}
}

// Benchmarks put the same comparison in a form CI can watch.
func BenchmarkLocked(b *testing.B) {
	tasks := Tasks(16, 2*time.Millisecond)
	ctx := context.Background()
	s := NewStore()
	for b.Loop() {
		s.RunLocked(ctx, tasks)
	}
}

func BenchmarkUnlocked(b *testing.B) {
	tasks := Tasks(16, 2*time.Millisecond)
	ctx := context.Background()
	s := NewStore()
	for b.Loop() {
		s.RunUnlocked(ctx, tasks)
	}
}
