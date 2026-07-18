package kube

import "testing"

// podTroubles must surface real faults (bad image, crash) and stay quiet for
// containers that are Ready or merely still starting — crying wolf during a
// normal rollout would make the panel noise, not signal.
func TestPodTroubles(t *testing.T) {
	mk := func(pod, container string, ready bool, waitReason, waitMsg, termReason string, exit int) podStatus {
		var p podStatus
		p.Metadata.Name = pod
		cs := struct {
			Name  string `json:"name"`
			Ready bool   `json:"ready"`
			State struct {
				Waiting *struct {
					Reason  string `json:"reason"`
					Message string `json:"message"`
				} `json:"waiting"`
				Terminated *struct {
					Reason   string `json:"reason"`
					Message  string `json:"message"`
					ExitCode int    `json:"exitCode"`
				} `json:"terminated"`
			} `json:"state"`
		}{Name: container, Ready: ready}
		if waitReason != "" {
			cs.State.Waiting = &struct {
				Reason  string `json:"reason"`
				Message string `json:"message"`
			}{Reason: waitReason, Message: waitMsg}
		}
		if termReason != "" {
			cs.State.Terminated = &struct {
				Reason   string `json:"reason"`
				Message  string `json:"message"`
				ExitCode int    `json:"exitCode"`
			}{Reason: termReason, ExitCode: exit}
		}
		p.Status.ContainerStatuses = append(p.Status.ContainerStatuses, cs)
		return p
	}

	got := podTroubles([]podStatus{
		mk("web-abc", "app", false, "ImagePullBackOff", "can't pull image", "", 0), // fault
		mk("ok-xyz", "app", true, "", "", "", 0),                                   // Ready → skip
		mk("boot-1", "app", false, "ContainerCreating", "", "", 0),                 // starting → skip
		mk("crash-9", "app", false, "", "", "Error", 1),                            // crashed → fault
		mk("done-2", "app", false, "", "", "Completed", 0),                         // clean exit → skip
	})

	if len(got) != 2 {
		t.Fatalf("expected 2 troubles (ImagePullBackOff + crash), got %d: %+v", len(got), got)
	}
	// Sorted by pod name: crash-9 before web-abc.
	if got[0].Pod != "crash-9" || got[0].Reason != "Error" {
		t.Errorf("first trouble = %+v, want crash-9/Error", got[0])
	}
	if got[1].Pod != "web-abc" || got[1].Reason != "ImagePullBackOff" {
		t.Errorf("second trouble = %+v, want web-abc/ImagePullBackOff", got[1])
	}
}

func TestBenignWaiting(t *testing.T) {
	for _, r := range []string{"", "ContainerCreating", "PodInitializing"} {
		if !benignWaiting(r) {
			t.Errorf("benignWaiting(%q) = false, want true", r)
		}
	}
	for _, r := range []string{"ImagePullBackOff", "CrashLoopBackOff", "ErrImagePull", "CreateContainerConfigError"} {
		if benignWaiting(r) {
			t.Errorf("benignWaiting(%q) = true, want false (it's a real fault)", r)
		}
	}
}

// Hint must turn the reasons we know about into an actionable line, and stay
// silent (rather than guess) for ones we don't.
func TestPodTroubleHint(t *testing.T) {
	for _, reason := range []string{"ImagePullBackOff", "ErrImagePull", "CrashLoopBackOff", "CreateContainerConfigError", "OOMKilled", "RunContainerError"} {
		if (PodTrouble{Reason: reason}).Hint() == "" {
			t.Errorf("Hint for %q is empty, want an actionable line", reason)
		}
	}
	for _, reason := range []string{"", "SomeFutureReason", "Completed"} {
		if h := (PodTrouble{Reason: reason}).Hint(); h != "" {
			t.Errorf("Hint for %q = %q, want \"\" (don't guess)", reason, h)
		}
	}
}

func TestDiagnosticsEmpty(t *testing.T) {
	if !(Diagnostics{}).Empty() {
		t.Error("zero Diagnostics should be Empty")
	}
	if (Diagnostics{PodTroubles: []PodTrouble{{Pod: "x"}}}).Empty() {
		t.Error("Diagnostics with a pod trouble is not Empty")
	}
	if (Diagnostics{Warnings: []Event{{Reason: "x"}}}).Empty() {
		t.Error("Diagnostics with a warning is not Empty")
	}
}

// Application.Why surfaces the message of a False condition (where Crossplane
// records the composition error) and stays quiet otherwise.
func TestApplicationWhy(t *testing.T) {
	var a Application
	if a.Why() != "" {
		t.Errorf("no conditions → Why() = %q, want \"\"", a.Why())
	}
	a.Status.Conditions = []Condition{
		{Type: "Synced", Status: "True"},
		{Type: "Ready", Status: "False", Message: "cannot resolve resources: bucket not ready"},
	}
	if got := a.Why(); got != "cannot resolve resources: bucket not ready" {
		t.Errorf("Why() = %q, want the False condition's message", got)
	}
	a.Status.Conditions = []Condition{{Type: "Ready", Status: "True"}}
	if got := a.Why(); got != "" {
		t.Errorf("Ready app → Why() = %q, want \"\"", got)
	}
}
