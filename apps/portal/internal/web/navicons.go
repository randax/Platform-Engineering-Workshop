package web

// Nav icons — a tiny, hand-picked inline-SVG set (Feather-style stroke glyphs),
// one per nav page, embedded in the binary like everything else (no icon font,
// no CDN). Keyed by the page's registry Key; navIcon returns "" for anything
// without an icon, so an unmapped page simply renders without one.

import "html/template"

const navIcoOpen = `<svg class="nav-ico" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">`

var navIcons = map[string]template.HTML{
	// Platform
	"overview":   template.HTML(navIcoOpen + `<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/></svg>`),
	"components": template.HTML(navIcoOpen + `<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/></svg>`),
	"access":     template.HTML(navIcoOpen + `<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>`),
	"workshop":   template.HTML(navIcoOpen + `<path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg>`),
	"streams":    template.HTML(navIcoOpen + `<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.6" y1="13.5" x2="15.4" y2="17.5"/><line x1="15.4" y1="6.5" x2="8.6" y2="10.5"/></svg>`),
	"activity":   template.HTML(navIcoOpen + `<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>`),
	"billing":    template.HTML(navIcoOpen + `<rect x="1" y="4" width="22" height="16" rx="2"/><line x1="1" y1="10" x2="23" y2="10"/></svg>`),
	"builds":     template.HTML(navIcoOpen + `<path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/></svg>`),
	// Self-service
	"databases": template.HTML(navIcoOpen + `<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>`),
	"buckets":   template.HTML(navIcoOpen + `<polyline points="21 8 21 21 3 21 3 8"/><rect x="1" y="3" width="22" height="5" rx="1"/><line x1="10" y1="12" x2="14" y2="12"/></svg>`),
	"services":  template.HTML(navIcoOpen + `<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>`),
	// Capstone
	"gallery": template.HTML(navIcoOpen + `<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>`),
}

// navIcon returns the inline SVG for a nav page key, or "" if none.
func navIcon(key string) template.HTML { return navIcons[key] }
