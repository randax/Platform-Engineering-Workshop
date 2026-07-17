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
	// Services
	// "Applications" — a dashboard/app-window frame: the composite workload.
	"applications": template.HTML(navIcoOpen + `<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18"/><path d="M9 21V9"/></svg>`),
	"databases":    template.HTML(navIcoOpen + `<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>`),
	"buckets":   template.HTML(navIcoOpen + `<polyline points="21 8 21 21 3 21 3 8"/><rect x="1" y="3" width="22" height="5" rx="1"/><line x1="10" y1="12" x2="14" y2="12"/></svg>`),
	// Functions — a lightning bolt (Feather "zap"): the serverless glyph.
	"services": template.HTML(navIcoOpen + `<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>`),
	// Capstone
	"gallery": template.HTML(navIcoOpen + `<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>`),
}

// navIcon returns the inline SVG for a nav page key, or "" if none.
func navIcon(key string) template.HTML { return navIcons[key] }

// General-purpose inline icons (Lucide, MIT) — replace decorative emoji in the
// templates with crisp, theme-aware SVG that inherits text colour and size
// (1em). Same offline, no-CDN approach as navIcons above. Add entries as needed.
const iconOpen = `<svg class="ico" viewBox="0 0 24 24" width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="vertical-align:-0.14em">`

var icons = map[string]template.HTML{
	"lock":    template.HTML(iconOpen + `<rect width="18" height="11" x="3" y="11" rx="2" ry="2" /><path d="M7 11V7a5 5 0 0 1 10 0v4" /></svg>`),
	"menu":    template.HTML(iconOpen + `<path d="M4 5h16" /><path d="M4 12h16" /><path d="M4 19h16" /></svg>`),
	"hexagon": template.HTML(iconOpen + `<path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" /></svg>`),
}

// icon returns the inline SVG for a name, or "" if none.
func icon(name string) template.HTML { return icons[name] }
