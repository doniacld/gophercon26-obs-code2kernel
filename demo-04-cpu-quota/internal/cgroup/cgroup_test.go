package cgroup

import (
	"math"
	"testing"
)

// The parsing tests exercise the pure logic on literal file contents rather than
// on /sys, so they pass on macOS. That matters: this repository is authored and
// rehearsed on a Mac, and a test that can only run inside a container is a test
// nobody runs.

func TestQuotaCores(t *testing.T) {
	tests := []struct {
		name  string
		quota Quota
		want  float64
	}{
		// The exact strings Docker writes for --cpus=0.25 and --cpus=2.
		{"quarter core", Quota{QuotaUS: 25000, PeriodUS: 100000}, 0.25},
		{"two cores", Quota{QuotaUS: 200000, PeriodUS: 100000}, 2},
		{"unlimited", Quota{Unlimited: true, PeriodUS: 100000}, 0},
		// A zero period would divide by zero rather than report nonsense.
		{"no period", Quota{QuotaUS: 25000}, 0},
	}
	for _, tt := range tests {
		if got := tt.quota.Cores(); math.Abs(got-tt.want) > 1e-9 {
			t.Errorf("%s: Cores() = %v, want %v", tt.name, got, tt.want)
		}
	}
}

func TestQuotaString(t *testing.T) {
	if got := (Quota{Unlimited: true}).String(); got != "unlimited" {
		t.Errorf("String() = %q, want %q", got, "unlimited")
	}
	got := Quota{QuotaUS: 25000, PeriodUS: 100000}.String()
	want := "0.25 cores (25000us per 100000us period)"
	if got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
}

func TestThrottledRatio(t *testing.T) {
	tests := []struct {
		name string
		stat Stat
		want float64
	}{
		// The demo's headline: every enforcement period cut short.
		{"every period", Stat{NrPeriods: 4, NrThrottled: 4}, 1},
		{"half", Stat{NrPeriods: 10, NrThrottled: 5}, 0.5},
		{"none", Stat{NrPeriods: 10}, 0},
		// No quota means no periods, and 0/0 must not be NaN — this value is
		// JSON-encoded by /throttle, and NaN is not valid JSON.
		{"no periods", Stat{}, 0},
	}
	for _, tt := range tests {
		got := tt.stat.ThrottledRatio()
		if math.IsNaN(got) {
			t.Errorf("%s: ThrottledRatio() is NaN — it would break JSON encoding", tt.name)
			continue
		}
		if math.Abs(got-tt.want) > 1e-9 {
			t.Errorf("%s: ThrottledRatio() = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// TestSub is what makes /throttle report on one load run rather than on the
// container's whole lifetime.
func TestSub(t *testing.T) {
	earlier := Stat{
		UsageUS: 1000, UserUS: 900, SystemUS: 100,
		NrPeriods: 10, NrThrottled: 2, ThrottledUS: 5000,
		NrBursts: 1, BurstUS: 50,
	}
	now := Stat{
		UsageUS: 4000, UserUS: 3500, SystemUS: 500,
		NrPeriods: 14, NrThrottled: 6, ThrottledUS: 658504,
		NrBursts: 3, BurstUS: 150,
		present: map[string]bool{"nr_bursts": true},
	}

	d := now.Sub(earlier)
	for _, c := range []struct {
		field string
		got   int64
		want  int64
	}{
		{"UsageUS", d.UsageUS, 3000},
		{"UserUS", d.UserUS, 2600},
		{"SystemUS", d.SystemUS, 400},
		{"NrPeriods", d.NrPeriods, 4},
		{"NrThrottled", d.NrThrottled, 4},
		{"ThrottledUS", d.ThrottledUS, 653504},
		{"NrBursts", d.NrBursts, 2},
		{"BurstUS", d.BurstUS, 100},
	} {
		if c.got != c.want {
			t.Errorf("Sub().%s = %d, want %d", c.field, c.got, c.want)
		}
	}

	// The delta must show 4 of 4 periods throttled — the reveal — not 6 of 14,
	// which is what a raw total would say.
	if r := d.ThrottledRatio(); r != 1 {
		t.Errorf("delta ThrottledRatio() = %v, want 1", r)
	}
	// Field presence has to survive the subtraction, or /throttle would stop
	// reporting nr_bursts on kernels that do supply it.
	if !d.Has("nr_bursts") {
		t.Error("Sub() lost the field-presence map")
	}
}

func TestHasOnZeroValue(t *testing.T) {
	// A Stat that was never read has a nil present map; Has must not panic.
	var s Stat
	if s.Has("nr_bursts") {
		t.Error("Has() on a zero Stat reported a field that was never read")
	}
}
