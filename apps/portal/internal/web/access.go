package web

// The Access page: "who am I?" for the console itself. It answers, from the
// cluster's own mouth, the module-08 punchline — the portal has no special
// powers. It reads exactly these resources with a read-only ServiceAccount,
// and here is the API server's own list to prove it.
//
// The mechanism is a SelfSubjectRulesReview: a token may always ask what it is
// allowed to do (the review is self-scoped, so no RBAC gates it). The reply is
// what `kubectl auth can-i --list` prints — and for this console it should be
// a small, verbs-are-get/list/watch, read-only surface. This page is meta and
// security-flavoured, so it is ALWAYS unlocked: useful even from a bare
// cluster, before any capability has been installed.

import (
	"context"
	"net/http"
	"strings"

	"cloudbox.io/portal/internal/kube"
)

func init() {
	register(Page{
		Weight:     25, // right after Components in the Platform group
		NavSection: "Platform",
		NavTitle:   "Access",
		Path:       "/access",
		Handler:    handleAccess,
		// No Unlock: this is meta/security, not a capability. It must be
		// reachable from a bare cluster.
	})
}

// ruleRow is one flattened (verbs × resources) line for the table — a rule's
// string slices joined the way `kubectl auth can-i --list` renders them.
type ruleRow struct {
	APIGroups string
	Resources string
	Verbs     string
}

type accessData struct {
	Namespace  string    // the namespace the review was scoped to (the pod's own)
	Rules      []ruleRow // what the ServiceAccount may do there
	Incomplete bool      // the API server couldn't enumerate every rule
	Flash      flash     // set only when self-review itself failed (rare)
}

// accessRows flattens a SelfRules into display rows, one per resource rule,
// mapping the core group's "" to a readable "core".
func accessRows(sr kube.SelfRules) []ruleRow {
	rows := make([]ruleRow, 0, len(sr.ResourceRules))
	for _, r := range sr.ResourceRules {
		rows = append(rows, ruleRow{
			APIGroups: groupList(r.APIGroups),
			Resources: strings.Join(r.Resources, ", "),
			Verbs:     strings.Join(r.Verbs, ", "),
		})
	}
	return rows
}

// groupList renders apiGroups for humans: the core API group is the empty
// string on the wire, which reads as nothing — call it "core" instead.
func groupList(groups []string) string {
	out := make([]string, len(groups))
	for i, g := range groups {
		if g == "" {
			g = "core"
		}
		out[i] = g
	}
	return strings.Join(out, ", ")
}

// selfRuler is the one slice of the kube client this page consumes — a
// consumer-side interface, so the page logic can be tested with a fake source
// instead of a live API server.
type selfRuler interface {
	SelfRules(ctx context.Context, ns string) (kube.SelfRules, error)
}

func fetchAccess(ctx context.Context, r selfRuler, ns string) (accessData, error) {
	sr, err := r.SelfRules(ctx, ns)
	if err != nil {
		return accessData{}, err
	}
	return accessData{
		Namespace:  ns,
		Rules:      accessRows(sr),
		Incomplete: sr.Incomplete,
	}, nil
}

func handleAccess(s *Server, w http.ResponseWriter, r *http.Request) {
	// Scope the review to our own namespace when we know it; a bare "default"
	// is the honest fallback when running outside a cluster (kubectl proxy).
	ns := s.Kube.Namespace()
	if ns == "" {
		ns = "default"
	}
	data, err := fetchAccess(r.Context(), s.Kube, ns)
	if err != nil {
		// A self-review being refused is unlikely — it is self-scoped — but a
		// bare cluster or a proxy without the authorization API could still say
		// no. Degrade to a friendly message rather than a bare 500.
		data = accessData{
			Namespace: ns,
			Flash:     errorFlash("Could not read our own permissions: " + err.Error()),
		}
	}
	s.render(w, "access", data)
}
