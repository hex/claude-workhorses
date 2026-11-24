// ABOUTME: The workhorse-runs mod's session state: the wh badge's text and the band's run lines while runs from this session's folder go.
// ABOUTME: The footer badge and the band above the prompt read it; the run-log poll writes it.
// "↗ wh - gamma 0:42" while the repository is still copying to the workhorse, a spinner frame for the arrow
// once the job runs; null with no run.
export type Badge = string | null
// One line per run, oldest first: the label "wh gamma:" and the detail "pnpm test (demo) · 0:42"; empty with no run.
export type RunLines = readonly { label: string; detail: string }[]

declare module 'claude-code' {
  interface PluginState {
    'claude-workhorses': { badge: Badge; runLines: RunLines }
  }
}
