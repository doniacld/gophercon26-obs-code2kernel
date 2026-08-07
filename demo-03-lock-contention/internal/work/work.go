// Package work computes independent CPU-bound results and stores them in shared
// state, twice: once with the expensive computation inside the critical section,
// once with it outside.
//
// The two functions launch identical goroutines, do identical work, and produce
// identical results. The only difference is three lines of lock placement:
//
//	locked                          unlocked
//	mu.Lock()                       result := expensiveWork(input)
//	result := expensiveWork(input)   mu.Lock()
//	storeResult(result)             storeResult(result)
//	mu.Unlock()                     mu.Unlock()
//
// That is the whole demo. "Concurrent" describes the structure of the code;
// "parallel" describes what the hardware actually did. Only one of these two
// achieves the second, and no amount of reading the source makes it obvious
// which.
//
// The mutex is a field on a single Store shared by every request, not a local
// inside one. A per-request mutex would serialize each request against itself;
// a shared one serializes the whole process, which is what makes it a
// process-wide throughput ceiling rather than a per-request slowdown.
package work

import (
	"context"
	"fmt"
	"hash/fnv"
	"runtime"
	"runtime/trace"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// Task is one unit of independent CPU work.
type Task struct {
	ID       int
	Duration time.Duration
}

// Result is one task's outcome.
type Result struct {
	ID       int    `json:"id"`
	Checksum uint64 `json:"checksum"`

	// LockWait is how long this task waited to acquire the mutex. Summed across
	// tasks it is the application's own measurement of contention, and it
	// corroborates the mutex profile from a completely independent direction —
	// which is worth having when a number on stage looks too good to be true.
	LockWait time.Duration `json:"lock_wait_us"`
	Started  time.Duration `json:"started_us"`  // offset from batch start
	Finished time.Duration `json:"finished_us"` // offset from batch start
}

// Batch is the outcome of one request.
type Batch struct {
	Mode    string   `json:"mode"`
	Results []Result `json:"results"`

	Wall time.Duration `json:"wall_us"`
	// CPUTime is the sum of the tasks' own durations. Compare it with Wall:
	//   Wall ~= CPUTime            -> the tasks ran one after another
	//   Wall ~= CPUTime / N        -> N of them ran at once
	// Computed from timestamps the handler already has, with no profiler
	// involved: an application can report that it is failing to use its cores.
	CPUTime  time.Duration `json:"cpu_time_us"`
	LockWait time.Duration `json:"lock_wait_us"`

	Items int `json:"items"`
	// PeakWorking is the most tasks *from this batch* that were ever inside
	// expensiveWork at the same time. It is scoped to the batch rather than to the
	// process on purpose: a single request's peak is a statement about that
	// request, and reading the process-wide peak here would report 83 for a
	// 16-task request that happened to follow a load run. /stats reports the
	// process-wide peak, which is the right scope for a question about the whole
	// service.
	PeakWorking int  `json:"peak_working"`
	GOMAXPROCS  int  `json:"gomaxprocs"`
	Cancelled   bool `json:"cancelled"`
}

// Speedup is CPUTime/Wall: how many tasks' worth of work the batch completed
// per unit of wall clock. 1.0 means fully serial.
func (b *Batch) Speedup() float64 {
	if b.Wall <= 0 {
		return 0
	}
	return b.CPUTime.Seconds() / b.Wall.Seconds()
}

// Store is the shared state every request writes into.
//
// It keeps the most recent result for each work-item index, so the map is
// bounded by the item count no matter how long the service runs, and every
// request genuinely contends for the same lock.
//
// This is real shared mutable state and it really does need a mutex. The fix in
// this demo is to hold that mutex for less time, never to delete it: a demo
// whose "fix" is removing synchronization teaches the wrong lesson, and
// `go test -race` would fail.
type Store struct {
	mu     sync.Mutex
	latest map[int]Result
	writes int64

	// Counters live outside the mutex, on purpose. A /stats endpoint that has to
	// acquire the lock it is reporting on would block for seconds in locked mode
	// — the diagnostic would be the first casualty of the bug it is meant to
	// describe. Atomics cost nothing here and keep observability independent of
	// the thing observed.
	requests   atomic.Int64
	tasks      atomic.Int64
	lockWaitUS atomic.Int64
	cancelled  atomic.Int64

	// live is the process-wide concurrency gauge: every task everywhere bumps it,
	// so its peak spans requests. Each batch keeps its own gauge as well, because
	// the two answer different questions — see Batch.PeakWorking.
	live gauge

	// obs is the optional metrics sink. Nil unless Observe was called.
	obs atomic.Pointer[Observer]
}

// gauge counts how many tasks are inside expensiveWork right now, and the most
// there have ever been at once.
//
// The peak is the clock-independent statement of this whole demo: in locked mode
// it is exactly 1 however fast the machine is, and no timing measurement is that
// robust.
type gauge struct {
	now  atomic.Int64
	peak atomic.Int64
}

// enter records one more task inside expensiveWork and returns the leave func.
func (g *gauge) enter() func() {
	now := g.now.Add(1)
	// A compare-and-swap loop, not a Store: two goroutines observing 7 and 8
	// must not race the recorded peak back down to 7.
	for {
		peak := g.peak.Load()
		if now <= peak || g.peak.CompareAndSwap(peak, now) {
			break
		}
	}
	return func() { g.now.Add(-1) }
}

func (g *gauge) reset() {
	g.peak.Store(0)
}

// Observer receives the two events that matter to a metrics backend: a worker
// entering and leaving the CPU-bound section, and how long a worker waited for
// the mutex.
//
// An interface rather than a direct dependency on the metrics package, for two
// reasons. This package stays importable by a test that wants no registry, and —
// more to the point — the instrumentation is visibly *additive*: the lock
// placement is still the only difference between the two modes, and no reader has
// to check whether a Prometheus call snuck inside a critical section.
type Observer interface {
	// WorkerEnter is called when a worker goroutine starts, whether it is
	// computing or queued on the mutex, and returns the func to call when it
	// finishes.
	WorkerEnter(mode string) func()
	// ObserveMutexWait reports one acquisition's wait, in seconds.
	ObserveMutexWait(mode string, seconds float64)
}

// NewStore returns an empty store.
func NewStore() *Store {
	return &Store{latest: make(map[int]Result)}
}

// Observe attaches an Observer. Passing nil detaches, which is the state every
// test that does not care about metrics runs in.
func (s *Store) Observe(o Observer) {
	s.obs.Store(&o)
}

// observer returns the attached Observer, or nil.
//
// Loaded through an atomic pointer because Observe may in principle be called
// while requests are in flight, and `go test -race` is part of this demo's
// validation — an unsynchronised field read here would fail it for a reason that
// has nothing to do with the demo's subject.
func (s *Store) observer() Observer {
	if p := s.obs.Load(); p != nil {
		return *p
	}
	return nil
}

// RunLocked holds the mutex across the expensive work — the bug.
//
// One goroutine per task, exactly as in RunUnlocked. Every one of them blocks on
// the same lock, and the goroutine holding it spends 100 ms burning CPU before
// releasing it. So although N goroutines exist and are runnable, exactly one
// makes progress at a time, process-wide, however many cores the machine has.
//
// This shape occurs in the wild wherever a lock protecting shared state is held
// across work that does not touch that state: a cache mutex held across the
// computation that produces the value, a metrics mutex held across a
// serialization, a "just to be safe" lock around a whole method. It is always
// correct, and it is why the fix is easy to overlook — there is no bug to find
// in the sense of wrong output.
func (s *Store) RunLocked(ctx context.Context, tasks []Task) *Batch {
	defer trace.StartRegion(ctx, "compute.locked").End()
	return s.run(ctx, "locked", tasks, true)
}

// RunUnlocked computes first and locks only to store — the fix.
//
// Identical goroutines, identical work, identical results. The critical section
// shrinks from 100 ms of hashing to a single map assignment: roughly a
// million-fold reduction, and the difference between a process that uses one
// core and a process that uses all of them.
func (s *Store) RunUnlocked(ctx context.Context, tasks []Task) *Batch {
	defer trace.StartRegion(ctx, "compute.unlocked").End()
	return s.run(ctx, "unlocked", tasks, false)
}

// run is shared by both modes so that the goroutine structure, the timing, the
// bookkeeping and the cancellation handling are provably identical and the only
// variable is lockFirst. Keeping them in one function is what lets the README
// claim the difference is three lines of lock placement.
func (s *Store) run(ctx context.Context, mode string, tasks []Task, lockFirst bool) *Batch {
	s.requests.Add(1)

	b := &Batch{
		Mode:       mode,
		Results:    make([]Result, len(tasks)),
		Items:      len(tasks),
		CPUTime:    totalDuration(tasks),
		GOMAXPROCS: runtime.GOMAXPROCS(0),
	}

	var (
		wg        sync.WaitGroup
		cancelled atomic.Bool
		batch     gauge // this batch's own concurrency peak
		start     = time.Now()
	)

	for i, t := range tasks {
		wg.Add(1)
		go func() {
			defer wg.Done()

			// demo3_active_workers counts a worker for its whole life, not only
			// the part that holds the lock. That is what makes the metric say
			// something: in locked mode it reads 128 while the process burns one
			// core, and a gauge scoped to expensiveWork would have read 1 and
			// quietly agreed with the CPU.
			if o := s.observer(); o != nil {
				defer o.WorkerEnter(mode)()
			}

			startedAt := time.Since(start)
			var (
				res      Result
				lockWait time.Duration
				ok       bool
			)
			if lockFirst {
				res, lockWait, ok = s.computeUnderLock(ctx, mode, &batch, t)
			} else {
				res, lockWait, ok = s.computeThenStore(ctx, mode, &batch, t)
			}
			if !ok {
				cancelled.Store(true)
				return
			}

			res.LockWait = lockWait
			res.Started = startedAt
			res.Finished = time.Since(start)
			// Slot i belongs to this task alone. Distinct indices in a
			// preallocated slice are independent memory, so the batch's own
			// results need no synchronisation — the Store's map is the shared
			// thing, and it is the only thing under the lock.
			b.Results[i] = res

			s.tasks.Add(1)
			s.lockWaitUS.Add(lockWait.Microseconds())
		}()
	}
	wg.Wait()

	b.Wall = time.Since(start)
	b.Cancelled = cancelled.Load()
	b.PeakWorking = int(batch.peak.Load())
	for _, r := range b.Results {
		b.LockWait += r.LockWait
	}
	if b.Cancelled {
		s.cancelled.Add(1)
	}
	return b
}

// computeUnderLock is the locked critical section:
//
//	mu.Lock()
//	result := expensiveWork(input)
//	storeResult(result)
//	mu.Unlock()
func (s *Store) computeUnderLock(ctx context.Context, mode string, batch *gauge, t Task) (Result, time.Duration, bool) {
	lockWait, ok := s.acquire(ctx, mode)
	if !ok {
		return Result{}, lockWait, false
	}
	defer s.mu.Unlock()

	// Everything below happens while every other goroutine in the process waits.
	res := s.expensiveWork(ctx, batch, t)
	s.storeLocked(res)
	return res, lockWait, true
}

// computeThenStore is the store-only critical section:
//
//	result := expensiveWork(input)
//	mu.Lock()
//	storeResult(result)
//	mu.Unlock()
func (s *Store) computeThenStore(ctx context.Context, mode string, batch *gauge, t Task) (Result, time.Duration, bool) {
	res := s.expensiveWork(ctx, batch, t)

	lockWait, ok := s.acquire(ctx, mode)
	if !ok {
		return Result{}, lockWait, false
	}
	defer s.mu.Unlock()

	s.storeLocked(res)
	return res, lockWait, true
}

// acquire takes the mutex and reports how long that took.
//
// The trace region is what makes the wait visible in `go tool trace`'s
// user-region view: in locked mode "lock.wait" covers almost the entire
// timeline, in unlocked mode it is invisible at any zoom level a projector can show.
//
// It also demonstrates something a demo about locks should not skip: a
// sync.Mutex has no context-aware Lock, so a goroutine queued on a mutex cannot
// be cancelled. All that can be done is to check the context *after* acquiring
// it and give the slot straight back. A lock held for 100 ms therefore makes
// every request behind it uncancellable for up to 100 ms per queued task, which
// is how one slow critical section defeats an entire timeout strategy.
func (s *Store) acquire(ctx context.Context, mode string) (time.Duration, bool) {
	region := trace.StartRegion(ctx, "lock.wait")
	queued := time.Now()
	s.mu.Lock()
	wait := time.Since(queued)
	region.End()

	// Reported after the lock is held, never inside the wait: the measurement
	// must not add work to the critical path it is measuring.
	if o := s.observer(); o != nil {
		o.ObserveMutexWait(mode, wait.Seconds())
	}

	if err := ctx.Err(); err != nil {
		s.mu.Unlock()
		return wait, false
	}
	return wait, true
}

// storeLocked writes one result. The caller must hold s.mu.
//
// This is the entire justification for the mutex: a map write, and a counter.
// Nanoseconds of work, guarded correctly. In unlocked mode this is all the lock
// ever covers.
func (s *Store) storeLocked(r Result) {
	s.latest[r.ID] = r
	s.writes++
}

// expensiveWork consumes approximately t.Duration of CPU and returns a checksum
// that depends only on the task ID.
//
// Real CPU work, not time.Sleep. A sleeping goroutine is off-CPU and would
// appear in the trace as a timer wait — a different phenomenon, and demo 4's
// subject. The point here is that the CPU *is* available and the program fails
// to use it, which only holds if the work is genuinely CPU-bound.
//
// The checksum must not depend on how many rounds fit in the duration, or a
// faster machine would compute a different answer and the equivalence test
// between the two modes would be meaningless. Each round resets the hash and
// performs a fixed number of writes, so every round computes the same value and
// only the *number* of rounds varies with the clock.
func (s *Store) expensiveWork(ctx context.Context, batch *gauge, t Task) Result {
	// Two gauges, two scopes: the batch's peak answers "did this request use the
	// machine?", the store's answers "did the service ever?".
	defer batch.enter()()
	defer s.live.enter()()

	defer trace.StartRegion(ctx, "work.compute").End()
	if trace.IsEnabled() {
		trace.Logf(ctx, "task", "id=%d duration=%s", t.ID, t.Duration)
	}

	seed := strconv.AppendInt([]byte("inside-out-go-programs/"), int64(t.ID), 10)
	h := fnv.New64a()
	deadline := time.Now().Add(t.Duration)
	var sum uint64
	for {
		// A few thousand hashes between clock reads: frequent enough to land
		// near the requested duration, rare enough that time.Now() is not what
		// the CPU profile ends up measuring.
		h.Reset()
		for range 4000 {
			_, _ = h.Write(seed)
		}
		sum = h.Sum64()
		if time.Now().After(deadline) || ctx.Err() != nil {
			return Result{ID: t.ID, Checksum: sum}
		}
	}
}

// Run dispatches on mode.
func (s *Store) Run(ctx context.Context, mode string, tasks []Task) (*Batch, error) {
	switch mode {
	case "locked":
		return s.RunLocked(ctx, tasks), nil
	case "unlocked":
		return s.RunUnlocked(ctx, tasks), nil
	default:
		return nil, fmt.Errorf("unknown mode %q, want locked or unlocked", mode)
	}
}

// Stats is the /stats payload.
type Stats struct {
	Requests      int64   `json:"requests"`
	Tasks         int64   `json:"tasks"`
	Working       int64   `json:"working_now"`
	PeakWorking   int64   `json:"peak_working"`
	StoredKeys    int     `json:"stored_keys"`
	Writes        int64   `json:"store_writes"`
	Cancelled     int64   `json:"cancelled_batches"`
	LockWaitMS    float64 `json:"total_lock_wait_ms"`
	AvgLockWaitMS float64 `json:"avg_lock_wait_ms"`
	Goroutines    int     `json:"goroutines"`
	GOMAXPROCS    int     `json:"gomaxprocs"`
}

// Stats snapshots the counters.
//
// PeakWorking is the number to watch: it is how many tasks were ever inside
// expensiveWork simultaneously. 1 means the process serialized itself no matter
// how many goroutines it created.
func (s *Store) Stats() Stats {
	tasks := s.tasks.Load()
	waitUS := s.lockWaitUS.Load()

	var avg float64
	if tasks > 0 {
		avg = float64(waitUS) / float64(tasks) / 1000
	}

	// The lock is taken only for the map length, and only here. It is the one
	// place /stats cannot avoid it — kept last and kept to one statement.
	s.mu.Lock()
	keys, writes := len(s.latest), s.writes
	s.mu.Unlock()

	return Stats{
		Requests:      s.requests.Load(),
		Tasks:         tasks,
		Working:       s.live.now.Load(),
		PeakWorking:   s.live.peak.Load(),
		StoredKeys:    keys,
		Writes:        writes,
		Cancelled:     s.cancelled.Load(),
		LockWaitMS:    float64(waitUS) / 1000,
		AvgLockWaitMS: avg,
		Goroutines:    runtime.NumGoroutine(),
		GOMAXPROCS:    runtime.GOMAXPROCS(0),
	}
}

// Reset zeroes the counters so a second run reports its own numbers. Without it,
// switching modes and reading /stats would show the locked mode's peak forever,
// and a mislabelled number on stage is worse than no number.
func (s *Store) Reset() {
	s.requests.Store(0)
	s.tasks.Store(0)
	s.lockWaitUS.Store(0)
	s.cancelled.Store(0)
	s.live.reset()

	s.mu.Lock()
	defer s.mu.Unlock()
	clear(s.latest)
	s.writes = 0
}

// Tasks builds n tasks of equal duration.
func Tasks(n int, d time.Duration) []Task {
	ts := make([]Task, n)
	for i := range ts {
		ts[i] = Task{ID: i, Duration: d}
	}
	return ts
}

func totalDuration(tasks []Task) time.Duration {
	var total time.Duration
	for _, t := range tasks {
		total += t.Duration
	}
	return total
}
