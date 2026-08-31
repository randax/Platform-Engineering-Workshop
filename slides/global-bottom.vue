<!--
  Slide numbers, bottom-right on every slide.

  A global-bottom component rather than a theme option: seriph has no page-number
  switch and Slidev has no headmatter one, and this survives a theme change.

  Hidden on the cover and the full-bleed terminal slide — a page number on the
  title card reads as a mistake, and the terminal is meant to look like a window
  with nothing floating over it.
-->
<script setup lang="ts">
import { computed } from 'vue'
import { useNav } from '@slidev/client'

const { currentPage, total, currentSlideRoute } = useNav()

const hidden = computed(() => {
  const fm: any = currentSlideRoute.value?.meta?.slide?.frontmatter ?? {}
  return fm.layout === 'cover' || String(fm.class ?? '').includes('term-slide')
})
</script>

<template>
  <div v-if="!hidden" class="slide-no">
    {{ currentPage }}<span class="sep">/</span>{{ total }}
  </div>
</template>

<style scoped>
.slide-no {
  position: absolute;
  right: 0.9rem;
  bottom: 0.55rem;
  z-index: 20;
  font-size: 0.68rem;
  font-variant-numeric: tabular-nums;
  opacity: 0.42;
  pointer-events: none;
  user-select: none;
}
.sep { margin: 0 0.18em; opacity: 0.6; }
</style>
