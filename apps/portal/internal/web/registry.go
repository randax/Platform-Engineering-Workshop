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
	NavSection string // sidebar group: Platform | Self-service | Capstone
	NavTitle   string
	Path       string // href and GET route ("/" is the overview)
	Handler    HandlerFunc
	Extra      []Route
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
}

// navGroups folds the page list into sidebar sections, preserving both the
// section order and the page order (both come from the weights).
func navGroups() []navGroup {
	var groups []navGroup
	for _, p := range Pages() {
		if len(groups) == 0 || groups[len(groups)-1].Label != p.NavSection {
			groups = append(groups, navGroup{Label: p.NavSection})
		}
		g := &groups[len(groups)-1]
		g.Items = append(g.Items, navItem{Href: p.Path, Title: p.NavTitle, Key: p.ActiveKey()})
	}
	return groups
}
