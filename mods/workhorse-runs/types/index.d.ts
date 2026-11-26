// ABOUTME: The workhorse-runs mod's session state: the wh badge's text and the band's run lines while runs from this session's folder go.
// ABOUTME: The footer badge and the band above the prompt read it; the run-log poll writes it.
// "wh ⇄ gamma 0:42" while the repository is still copying to the workhorse (⇄ and ⇆ in turn), a spinner
// frame in the arrows' place once the job runs; null with no run.
export type Badge = string | null
// One line per run, oldest first: its log id, the laptop pid wh stop takes (null for a run logged
// without one), the host "gamma", the time "0:42" or "copying 0:03", the repository "demo" and the
// command "pnpm test"; empty with no run.
export type RunLines = readonly {
  id: string
  pid: number | null
  host: string
  time: string
  repo: string
  command: string
}[]

declare module 'claude-code' {
  interface PluginState {
    'workhorses': { badge: Badge; runLines: Shaped<RunLines> }
  }
}
