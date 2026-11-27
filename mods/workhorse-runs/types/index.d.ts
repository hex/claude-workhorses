// ABOUTME: The workhorse-runs mod's session state: the wh badge's text and the band's run lines while runs from this session's folder go,
// ABOUTME: and the /workhorses pane's report of each workhorse; the footer badge, the band and the pane read it.
// "wh ⇄ gamma" while the repository is still copying to the workhorse (⇄ and ⇆ in turn), a spinner
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

// One run going on a workhorse, as wh hosts --json reports it: its lock's name in ~/work and its
// command. A run this laptop started and its run log lists carries the folder it started from, the pid
// wh stop takes and the id of the Claude Code session that started it (null when it was started outside
// Claude Code, or before wh recorded it). Any other run carries the machine, pid and start time its
// lock's owner line names, each null when the owner line is not one wh wrote.
export type HostRun =
  | { work: string; machine: string; pid: number; since: string; command: string; dir: string; session: string | null; stoppable: true }
  | {
      work: string
      machine: string | null
      pid: number | null
      since: string | null
      command: string
      dir: null
      session: null
      stoppable: false
    }
// One workhorse in the hosts file's order: its 1-minute load and physical cores with the runs going
// there, unreachable, or the answer it gave that is not a probe's, as plain text.
export type HostView =
  | { host: string; state: 'ok'; load: number; cores: number; runs: readonly HostRun[] }
  | { host: string; state: 'unreachable' }
  | { host: string; state: 'unexpected'; answer: string }
// The pane's report: when wh hosts last answered (ms; null before its first answer), the hosts it
// reported, and why the last refresh failed (null when it did not), the hosts kept from the one before.
export type HostsView = { checkedAt: number | null; hosts: readonly HostView[]; error: string | null }

declare module 'claude-code' {
  interface PluginState {
    'workhorses': { badge: Badge; runLines: Shaped<RunLines>; hostsView: Shaped<HostsView> }
  }
}
