package web

// THE extension point of the Cloudbox Console — and lab 08's going-deeper
// exercise. Every page in this package registers itself here; main.go
// ranges over Pages() to mount the routes, and the sidebar in layout.html
// is built from the same list. Adding a page is therefore ONE new file:
// copy an existing page file, change route + title + handler, done. No
// router edits, no template edits, no central list to forget.

import (
	"net/http"
	"sort"
	"strings"

	"cloudbox.io/portal/internal/kube"
)

// HandlerFunc is an http.HandlerFunc with the server's dependencies handed
// in — pages stay plain functions, wiring stays in main.
type HandlerFunc func(*Server, http.ResponseWriter, *http.Request)

// Route is one extra endpoint a page owns besides its GET page: polled
// fragments, form posts, deletes.
type Route struct {
	Pattern string // full mux pattern, e.g. "POST /databases"
	Handler HandlerFunc
}

// Page is one sidebar entry plus everything it serves.
type Page struct {
	// Weight fixes the sidebar position explicitly — map iteration order
	// would shuffle the nav on every restart, and init() order across files
	// is just "alphabetical by filename", which is not a design.
	Weight     int
	NavSection string // sidebar group: Platform | Services | Capstone
	NavTitle   string
	Path       string // href and GET route ("/" is the overview)
	Handler    HandlerFunc
	Extra      []Route

	// Unlock gates the page on live cluster state. Until the predicate holds,
	// the page renders locked in the sidebar (greyed, non-clickable, with a
	// hint) and its handler serves a teaser instead of the real feature. This
	// is honest gating: the backing API genuinely does not exist yet, so the
	// feature would only error. nil ⇒ always unlocked. The predicate is
	// re-evaluated per request against the snapshot cache, so a page lights up
	// the moment its capability lands — no restart, no cache to bust.
	Unlock     func(kube.Snapshot) bool
	LockedHint string // module that unlocks it, e.g. "Complete Module 06 · Serverless"
	Teaser     string // one sentence on what the page will do once unlocked
}

// ActiveKey is what the page passes to the "head" template so the sidebar
// can mark it with aria-current.
func (p Page) ActiveKey() string {
	if p.Path == "/" {
		return "overview"
	}
	return strings.TrimPrefix(p.Path, "/")
}

var registry []Page

func register(p Page) { registry = append(registry, p) }

// Pages returns every registered page in sidebar order.
func Pages() []Page {
	sorted := append([]Page(nil), registry...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Weight < sorted[j].Weight })
	return sorted
}

// navGroup is what the layout template renders the sidebar from.
type navGroup struct {
	Label string
	Items []navItem
}

type navItem struct {
	Href, Title, Key string
	Locked           bool   // capability not present yet: render greyed, no link
	Hint             string // LockedHint, shown as the locked item's tooltip
	Teaser           string // carried for symmetry with the locked page teaser
}

// navGroups folds the page list into sidebar sections, preserving both the
// section order and the page order (both come from the weights). It takes the
// current cluster snapshot so each page's Unlock predicate decides whether it
// renders as a live link or a locked entry.
func navGroups(snap kube.Snapshot) []navGroup {
	var groups []navGroup
	for _, p := range Pages() {
		if len(groups) == 0 || groups[len(groups)-1].Label != p.NavSection {
			groups = append(groups, navGroup{Label: p.NavSection})
		}
		g := &groups[len(groups)-1]
		item := navItem{Href: p.Path, Title: p.NavTitle, Key: p.ActiveKey()}
		// A page whose Unlock predicate the current state does not satisfy is
		// locked; nil Unlock means always available (Overview, Workshop, …).
		if p.Unlock != nil && !p.Unlock(snap) {
			item.Locked = true
			item.Hint = p.LockedHint
			item.Teaser = p.Teaser
		}
		g.Items = append(g.Items, item)
	}
	return groups
}

// lockedData is what the "locked" template renders: the teaser a gated page
// shows in place of its feature while the capability is still missing.
type lockedData struct {
	Title  string
	Key    string // active-key so the sidebar still marks where you are
	Hint   string
	Teaser string
}

// Gated wraps a page (or one of its Extra) handlers so that, while the page is
// locked, the request serves the teaser instead of the real feature — whose
// API isn't there yet and would only error. The predicate is checked per
// request against the live snapshot cache, so the page starts working the
// instant its capability appears. Pages without an Unlock are returned as-is.
func (p Page) Gated(h HandlerFunc) HandlerFunc {
	if p.Unlock == nil {
		return h
	}
	return func(s *Server, w http.ResponseWriter, r *http.Request) {
		if !p.Unlock(s.currentSnapshot()) {
			s.render(w, "locked", lockedData{
				Title:  p.NavTitle,
				Key:    p.ActiveKey(),
				Hint:   p.LockedHint,
				Teaser: p.Teaser,
			})
			return
		}
		h(s, w, r)
	}
}
