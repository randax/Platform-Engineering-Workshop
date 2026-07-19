<!--
  <Logo> — a vendored, OFFLINE brand logo on a subtle chip.
  All SVGs live in slides/public/logos/ (bundled at build — never a CDN, per the
  deck's offline rule). See public/logos/README.md for sources + licences.

  Usage:
    <Logo name="argocd" label />          full-color chip + "Argo CD" label
    <Logo name="aws" dim label />         muted "the old way" treatment (rent column)
    <Logo name="zot" text="zot" label />  text chip for a logo we don't vendor
-->
<script setup>
import { computed } from 'vue'

const props = defineProps({
  name:  { type: String, required: true },
  label: { type: [Boolean, String], default: false }, // true → default name; string → custom
  dim:   { type: Boolean, default: false },            // muted/grayscale "rented" look
  size:  { type: String, default: '2rem' },            // logo height
  text:  { type: String, default: '' },                // fallback glyph when there is no SVG
})

// One SVG can stand for a whole project family.
const ALIAS = {
  argocd: 'argo', 'argo-workflows': 'argo', argoworkflows: 'argo', workflows: 'argo',
  aws: 'amazonwebservices', azure: 'microsoftazure', gcp: 'googlecloud',
  otel: 'opentelemetry', cnpg: 'cloudnativepg', k8s: 'kubernetes',
  victoria: 'victoriametrics', vm: 'victoriametrics',
}
// Human-readable default labels (brand casing).
const DISPLAY = {
  kubernetes: 'Kubernetes', talos: 'Talos', cilium: 'Cilium', gitea: 'Gitea',
  argo: 'Argo', argocd: 'Argo CD', 'argo-workflows': 'Argo Workflows',
  cloudnativepg: 'CloudNativePG', cnpg: 'CloudNativePG', crossplane: 'Crossplane',
  grafana: 'Grafana', opentelemetry: 'OpenTelemetry', otel: 'OpenTelemetry',
  knative: 'Knative', nats: 'NATS', buildkit: 'BuildKit', zot: 'Zot',
  victoriametrics: 'VictoriaMetrics', docker: 'Docker', cloudbox: 'Cloudbox', containerd: 'containerd',
  aws: 'AWS', amazonwebservices: 'AWS', azure: 'Azure', microsoftazure: 'Azure',
  gcp: 'Google Cloud', googlecloud: 'Google Cloud',
}

const file = computed(() => ALIAS[props.name] || props.name)
const src = computed(() => `${import.meta.env.BASE_URL}logos/${file.value}.svg`)
const labelText = computed(() =>
  typeof props.label === 'string' ? props.label
  : (props.label ? (DISPLAY[props.name] || props.name) : ''))
</script>

<template>
  <span class="logo" :class="{ dim }">
    <span class="chip" :style="{ '--sz': size }">
      <img v-if="!text" :src="src" :alt="labelText || name" loading="eager" />
      <span v-else class="txt">{{ text }}</span>
    </span>
    <span v-if="labelText" class="lbl">{{ labelText }}</span>
  </span>
</template>

<style scoped>
.logo { display: inline-flex; align-items: center; gap: 0.5em; vertical-align: middle; }
.chip {
  display: inline-flex; align-items: center; justify-content: center;
  padding: 0.45em; border-radius: 0.6em;
  background: rgba(255, 255, 255, 0.92);
  box-shadow: 0 1px 3px rgba(15, 23, 42, 0.18), inset 0 0 0 1px rgba(15, 23, 42, 0.06);
}
.chip img { height: var(--sz); width: auto; max-width: calc(var(--sz) * 2.6); display: block; }
.txt {
  height: var(--sz); display: inline-flex; align-items: center; padding: 0 0.15em;
  font-weight: 800; font-size: calc(var(--sz) * 0.72); letter-spacing: -0.02em;
  color: var(--jz-ink, #0f172a);
}
.lbl { font-size: 0.92rem; font-weight: 600; opacity: 0.92; }
/* "the old way" — desaturated + dimmed, matched to the rent palette. */
.dim .chip { background: rgba(226, 232, 240, 0.7); box-shadow: inset 0 0 0 1px rgba(100, 116, 139, 0.25); }
.dim .chip img, .dim .txt { filter: grayscale(1); opacity: 0.55; }
.dim .lbl { color: var(--jz-rent, #64748b); font-weight: 500; }
</style>
