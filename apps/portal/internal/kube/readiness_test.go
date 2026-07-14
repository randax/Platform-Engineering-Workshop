package kube

import "testing"

func TestReadinessOf(t *testing.T) {
	cases := []struct {
		conds []Condition
		want  Readiness
	}{
		{[]Condition{{Type: "Ready", Status: "True"}}, Readiness{"Ready", "ok"}},
		{[]Condition{{Type: "Ready", Status: "False", Reason: "Creating"}}, Readiness{"Creating", "meh"}},
		{[]Condition{{Type: "Ready", Status: "Unknown", Reason: "Deploying"}}, Readiness{"Deploying", "meh"}},
		{[]Condition{{Type: "Ready", Status: "False"}}, Readiness{"Not ready", "meh"}},
		{nil, Readiness{"Not ready", "meh"}},
	}
	for _, c := range cases {
		if got := ReadinessOf(c.conds); got != c.want {
			t.Errorf("readinessOf(%v) = %v, want %v", c.conds, got, c.want)
		}
	}
}
