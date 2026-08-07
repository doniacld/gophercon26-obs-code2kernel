// Package cgroup reads the CPU quota and the CPU throttling counters that the
// Linux kernel keeps for the current process's cgroup.
//
// This is demo 4's primary evidence, and it is worth being clear about why it
// comes before eBPF. `cpu.stat` is a plain text file. It needs no privileges, no
// kernel headers, no BTF, no tracepoints and no tooling — just a read. It answers
// "was this process forbidden to run, and for how long?" exactly, as an integer
// counter maintained by the scheduler itself. Anything eBPF adds is detail on top
// of a fact these three numbers already establish.
//
// Everything here is cgroup v2 (the unified hierarchy), which is what every
// current container runtime configures. On a v1 host, or on macOS, the files are
// absent and the reads report that plainly rather than guessing — a demo that
// invents numbers when it cannot measure is worse than one that admits it.
package cgroup

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// ErrUnavailable means this process is not in a cgroup v2 hierarchy with CPU
// accounting — a non-Linux host, cgroup v1, or a kernel without the controller.
var ErrUnavailable = errors.New("cgroup v2 cpu controller not available")

// Root is where the cgroup v2 hierarchy is mounted. A process inside a container
// normally sees its own cgroup at the root of this mount, which is why the plain
// path works and no per-process path lookup is needed.
const Root = "/sys/fs/cgroup"

// Quota is the contents of cpu.max: how much CPU time this cgroup may use per
// period.
type Quota struct {
	// Raw is the file's literal contents, e.g. "25000 100000" or "max 100000".
	Raw string
	// QuotaUS is the allowance per period in microseconds. Zero when unlimited.
	QuotaUS int64
	// PeriodUS is the enforcement period in microseconds, typically 100000.
	PeriodUS int64
	// Unlimited reports whether cpu.max is "max" — no quota at all.
	Unlimited bool
}

// Cores expresses the quota as a number of CPUs, which is the unit people
// actually reason in: `docker run --cpus=0.25` produces "25000 100000", and 0.25
// is the number to put on a slide. Returns 0 when unlimited.
func (q Quota) Cores() float64 {
	if q.Unlimited || q.PeriodUS <= 0 {
		return 0
	}
	return float64(q.QuotaUS) / float64(q.PeriodUS)
}

// String renders the quota for a log line or a stats endpoint.
func (q Quota) String() string {
	if q.Unlimited {
		return "unlimited"
	}
	return fmt.Sprintf("%.2f cores (%dus per %dus period)", q.Cores(), q.QuotaUS, q.PeriodUS)
}

// ReadQuota reads /sys/fs/cgroup/cpu.max.
func ReadQuota() (Quota, error) {
	b, err := os.ReadFile(Root + "/cpu.max")
	if err != nil {
		return Quota{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}

	raw := strings.TrimSpace(string(b))
	fields := strings.Fields(raw)
	if len(fields) != 2 {
		return Quota{Raw: raw}, fmt.Errorf("cpu.max: cannot parse %q", raw)
	}

	q := Quota{Raw: raw}
	period, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil {
		return q, fmt.Errorf("cpu.max: period %q: %w", fields[1], err)
	}
	q.PeriodUS = period

	if fields[0] == "max" {
		q.Unlimited = true
		return q, nil
	}
	quota, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return q, fmt.Errorf("cpu.max: quota %q: %w", fields[0], err)
	}
	q.QuotaUS = quota
	return q, nil
}

// Stat is the contents of cpu.stat.
//
// The three fields that matter to this demo are NrPeriods, NrThrottled and
// ThrottledUS. The first two are counts of enforcement periods; the third is the
// total time this cgroup's tasks spent runnable-but-forbidden. Note that
// ThrottledUS is summed across tasks, so it can exceed wall-clock time — the same
// arithmetic as demo 3's contention delay, and worth saying out loud before an
// audience does the division and concludes the number is impossible.
type Stat struct {
	UsageUS     int64
	UserUS      int64
	SystemUS    int64
	NrPeriods   int64
	NrThrottled int64
	ThrottledUS int64
	NrBursts    int64
	BurstUS     int64
	present     map[string]bool
}

// ThrottledRatio is the fraction of enforcement periods in which this cgroup ran
// out of quota, in 0..1.
//
// This is the demo's clock-independent headline. A ratio of 1.0 means every
// single period was cut short — the workload wanted more CPU than the quota
// allows, without exception. Unlike a latency threshold it cannot flake on a
// loaded laptop, and unlike ThrottledUS it does not need explaining.
func (s Stat) ThrottledRatio() float64 {
	if s.NrPeriods <= 0 {
		return 0
	}
	return float64(s.NrThrottled) / float64(s.NrPeriods)
}

// Sub returns the delta between s and an earlier reading.
//
// Always show a delta, never a raw total. These counters are cumulative from
// process start, so a total taken after several load runs describes all of them
// at once. "This load run was throttled 47 times" is a statement about the
// experiment; "this container has been throttled 4,000 times since boot" is not.
func (s Stat) Sub(earlier Stat) Stat {
	return Stat{
		UsageUS:     s.UsageUS - earlier.UsageUS,
		UserUS:      s.UserUS - earlier.UserUS,
		SystemUS:    s.SystemUS - earlier.SystemUS,
		NrPeriods:   s.NrPeriods - earlier.NrPeriods,
		NrThrottled: s.NrThrottled - earlier.NrThrottled,
		ThrottledUS: s.ThrottledUS - earlier.ThrottledUS,
		NrBursts:    s.NrBursts - earlier.NrBursts,
		BurstUS:     s.BurstUS - earlier.BurstUS,
		present:     s.present,
	}
}

// Has reports whether the kernel supplied a given field. nr_bursts and burst_usec
// only exist on kernels with CFS burst support, and a demo should not print 0 for
// a number it never read.
func (s Stat) Has(field string) bool { return s.present[field] }

// ReadStat reads /sys/fs/cgroup/cpu.stat.
func ReadStat() (Stat, error) {
	f, err := os.Open(Root + "/cpu.stat")
	if err != nil {
		return Stat{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	defer f.Close()

	st := Stat{present: map[string]bool{}}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 {
			continue
		}
		v, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			continue
		}
		st.present[fields[0]] = true
		switch fields[0] {
		case "usage_usec":
			st.UsageUS = v
		case "user_usec":
			st.UserUS = v
		case "system_usec":
			st.SystemUS = v
		case "nr_periods":
			st.NrPeriods = v
		case "nr_throttled":
			st.NrThrottled = v
		case "throttled_usec":
			st.ThrottledUS = v
		case "nr_bursts":
			st.NrBursts = v
		case "burst_usec":
			st.BurstUS = v
		}
	}
	if err := sc.Err(); err != nil {
		return st, fmt.Errorf("cpu.stat: %w", err)
	}
	return st, nil
}

// Available reports whether the cgroup v2 CPU files can be read at all. Used to
// decide whether to advertise the throttling endpoints, so that on macOS the
// demo says "not available here" instead of serving zeros.
func Available() bool {
	_, err := os.Stat(Root + "/cpu.stat")
	return err == nil
}
