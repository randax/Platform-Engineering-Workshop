# JavaZone 2025 Workshop Slides

This directory contains the Slidev presentation for the "Cloud on Your Terms: Building Your Own Cloud-Native Platform" workshop.

## 🎯 Quick Start

```bash
# Start presentation in development mode
mise run slides:dev

# Or directly with npm
cd slides && npm run dev
```

Then open http://localhost:3030 to view the slides.

## 📊 Presenter Mode

For workshop delivery, use presenter mode to see notes and upcoming slides:

```bash
# Start presenter mode
mise run slides:presenter

# Or directly
cd slides && npm run dev -- --presenter
```

## 📄 Export Options

```bash
# Export to PDF
mise run slides:export

# Build for deployment
mise run slides:build
```

## 🎨 Customization

The slides are built with:
- **Slidev** - Modern slide framework for developers
- **Vue.js** - Interactive components and animations
- **Mermaid** - Diagrams and flowcharts
- **Shiki** - Code highlighting with magic transitions

### Key Features Used

- **Magic Move** - Smooth code transitions between examples
- **Click Animations** - Progressive disclosure of content
- **Mermaid Diagrams** - Architecture and flow diagrams
- **Code Highlighting** - Kubernetes YAML, bash scripts, SQL
- **Interactive Elements** - Vue components for engagement

## 📂 Structure

```
slides/
├── slides.md              # Main presentation content
├── components/             # Custom Vue components
├── pages/                  # Additional slide pages
├── public/                 # Static assets (images, etc.)
└── package.json           # Dependencies and scripts
```

## 🎤 Workshop Flow

The presentation is structured to align with the hands-on labs:

1. **Introduction** - Workshop overview and objectives
2. **Foundation** - Talos Kubernetes setup (Lab 1)
3. **Database Platform** - CloudNativePG demo (Lab 2)
4. **Event Streaming** - Kafka implementation (Lab 3)
5. **Platform Complete** - Final architecture overview

## 💡 Tips for Presenters

- Use **Space** or **Arrow Keys** to navigate
- **Click animations** reveal content progressively
- **Presenter mode** shows notes and next slide
- **Drawing mode** available for annotations
- **Export to PDF** for offline backup

## 🔧 Troubleshooting

### Development Server Issues

```bash
# Clear cache and restart
rm -rf node_modules/.cache
npm run dev
```

### Export Problems

```bash
# Install Playwright for PDF export
npx playwright install chromium
npm run export
```

### Port Conflicts

```bash
# Use different port
npm run dev -- --port 3031
```

## 🌐 Deployment

For hosting the slides online:

```bash
# Build static site
npm run build

# Deploy dist/ folder to:
# - Netlify, Vercel, GitHub Pages
# - Or any static hosting service
```

The slides integrate perfectly with the workshop repository structure and can be updated alongside lab content using Git workflows.
