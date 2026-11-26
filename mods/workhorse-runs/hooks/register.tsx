// ABOUTME: Watches the workhorse run log that mirror.sh writes and shows the wh runs started from this session's folder.
// ABOUTME: While one runs, a green wh badge sits in the prompt footer, counting the copy to the workhorse, then spinning while the job runs;
// ABOUTME: the band above the prompt names each run with a Stop button, and a toast marks a long, BLOCKED or stopped end.
import { atom, read, update } from 'claude-code'
import type { Register, Timer } from 'claude-code'

import type { Badge, RunLines } from '../types'

const LOG = '.local/state/workhorse/runs.jsonl'
// Each second, so the badge's count of the copy ticks by one.
const POLL_MS = 1000
// The first read takes only the log's tail: enough to find the runs still going.
const TAIL_BYTES = 262144
// Quick runs show only in the band and the badge; a run this long gets a toast when it ends.
const LONG_RUN_SECONDS = 120
// How often runs still going are checked for a mirror.sh that died before writing its end line.
const LIVENESS_MS = 15000
// The theme's key for the green of the session-name tag, so the badge follows light and dark themes.
export const BADGE_GREEN = 'green_FOR_SUBAGENTS_ONLY'
// The arrow marks work being sent off the laptop, while the copy runs.
const COPYING_MARK = '↗'
// A braille spinner turns while the job itself runs on the workhorse.
const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
const SPIN_MS = 100
// The band above the prompt is shared with other mods' rows: this mod's row names at most this many
// runs, then counts the rest on one more line.
const BAND_MAX_RUNS = 3
// Powerline half circles (Nerd Fonts) drawn in the green give the badge rounded ends.
const ROUND_LEFT = '\ue0b6'
const ROUND_RIGHT = '\ue0b4'

const badge = atom({ plugin: 'claude-workhorses', key: 'badge' } as const, null as Badge)
const runLines = atom({ plugin: 'claude-workhorses', key: 'runLines' } as const, [] as RunLines, { shape: 'run-lines-2' })
// The band's label, as the claude-bloodhounds band opens its row; later rows keep its width blank.
const BAND_LABEL = `${COPYING_MARK} workhorses`
// The grey of the rule between the label and the runs.
const RULE = 'gray'

// pid is the laptop pid of the mirror.sh run; log lines written before it was recorded lack it.
type Start = { event: 'start'; id: string; at: number; host: string; dir: string; command: string; pid?: number }
// The copy on the workhorse matches the laptop and the job is starting.
type Synced = { event: 'synced'; id: string; at: number }
type End = { event: 'end'; id: string; at: number; exit: number; reason?: string }
type Entry = Start | Synced | End

export function parseEntries(text: string): Entry[] {
  const entries: Entry[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    const value = JSON.parse(line) as Entry
    if (value.event !== 'start' && value.event !== 'synced' && value.event !== 'end') {
      throw new Error(`workhorse run log: unknown event in line ${JSON.stringify(line)}`)
    }
    entries.push(value)
  }
  return entries
}

function bytes(text: string): number {
  return new TextEncoder().encode(text).length
}

function repoName(dir: string): string {
  return dir.slice(dir.lastIndexOf('/') + 1)
}

// The skill wraps every job in gtimeout; that guard and its options say nothing about the job itself.
const TIMEOUT_PREFIX = /^g?timeout(?:\s+(?:-[ks]\s+\S+|-\S+))*\s+\d+(?:\.\d+)?[smhd]?\s+(?=\S)/

// A script passed to sh -c spans lines; its whitespace collapses so the description is one line.
export function describe(start: Pick<Start, 'host' | 'dir' | 'command'>): string {
  return `${start.host}: ${runDetail(start)}`
}

// The run's command on one line, without its gtimeout guard.
function runCommand(start: Pick<Start, 'command'>): string {
  return start.command.replace(/\s+/g, ' ').trim().replace(TIMEOUT_PREFIX, '')
}

// What the run does: its command and the repository it runs in.
function runDetail(start: Pick<Start, 'dir' | 'command'>): string {
  return `${runCommand(start)} (${repoName(start.dir)})`
}

export function duration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds))
  const minutes = Math.floor(total / 60)
  return minutes === 0 ? `${total}s` : `${minutes}m${String(total % 60).padStart(2, '0')}s`
}

function isBlocked(end: End): boolean {
  return end.exit === 3 && end.reason !== undefined
}

export function deservesToast(start: Start | undefined, end: End): boolean {
  return isBlocked(end) || (start !== undefined && end.at - start.at >= LONG_RUN_SECONDS)
}

export function endToast(start: Start | undefined, end: End): string {
  const what = start === undefined ? `run ${end.id}` : describe(start)
  const took = start === undefined ? '' : ` after ${duration(end.at - start.at)}`
  const result = isBlocked(end) ? `BLOCKED: ${end.reason}` : end.reason === 'stopped' ? 'stopped' : `exit ${end.exit}`
  return `wh ${what} ended${took}, ${result}`
}

// Reads `ps -o pid=,command=` output and returns the pids that still belong to a mirror.sh run.
export function livePids(psOutput: string): Set<number> {
  const live = new Set<number>()
  for (const line of psOutput.split('\n')) {
    const [, pid, command] = /^\s*(\d+)\s+(.*)$/.exec(line) ?? []
    if (pid !== undefined && command !== undefined && command.includes('mirror.sh')) live.add(Number(pid))
  }
  return live
}

// A run belongs to the session when its repository and the session folder hold one another: a run
// from a worktree inside the session folder, or from the repository the session sits in.
export function belongsTo(dir: string, sessionDir: string): boolean {
  const inside = (path: string, folder: string) => folder === '/' || path === folder || path.startsWith(`${folder}/`)
  return inside(dir, sessionDir) || inside(sessionDir, dir)
}

// m:ss, the minutes running past 59.
function clock(seconds: number): string {
  const total = Math.max(0, Math.round(seconds))
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
}

// The badge's text: none without a run; else the workhorses the runs went to, each once, with the
// time the oldest copy has taken while any run is still copying; once every job runs, a spinner frame
// that steps every SPIN_MS and the time since the oldest run started.
export function badgeText(active: Iterable<Start>, copying: ReadonlySet<string>, nowMs: number): Badge {
  const runs = [...active]
  if (runs.length === 0) return null
  const hosts = [...new Set(runs.map(start => start.host))].sort().join(', ')
  const starts = runs.filter(start => copying.has(start.id)).map(start => start.at)
  if (starts.length > 0) return `${COPYING_MARK} wh - ${hosts} ${clock(nowMs / 1000 - Math.min(...starts))}`
  const oldest = Math.min(...runs.map(start => start.at))
  return `${SPINNER[Math.floor(nowMs / SPIN_MS) % SPINNER.length]} wh - ${hosts} ${clock(nowMs / 1000 - oldest)}`
}

// The band's lines: each run on its own, in the order the runs started, its time counting the copy
// while the copy runs. The band, not the engine's status line, because the engine draws every mod's
// status line as a warning. pid is what wh stop takes; a run logged without one has no Stop button.
export function bandLines(active: Iterable<Start>, copying: ReadonlySet<string>, nowSeconds: number): RunLines {
  return [...active].map(start => ({
    id: start.id,
    pid: start.pid ?? null,
    host: start.host,
    time: `${copying.has(start.id) ? 'copying ' : ''}${clock(nowSeconds - start.at)}`,
    repo: repoName(start.dir),
    command: runCommand(start),
  }))
}

export const register: Register = on => {
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const modes = await next(e)
    const text = await read($, badge)
    if (text === null) return modes
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="row" gap={1}>
        <Box flexDirection="row">
          <Text color={BADGE_GREEN}>{ROUND_LEFT}</Text>
          <Text color="white" weight="bold" backgroundColor={BADGE_GREEN}>
            {text}
          </Text>
          <Text color={BADGE_GREEN}>{ROUND_RIGHT}</Text>
        </Box>
        {modes}
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const lines = await read($, runLines)
    if (lines.length === 0) return next(e)
    const hidden = lines.length - BAND_MAX_RUNS
    const { Box, Button, Text } = $.ui.resolve(e)
    const stop = async (pid: number) => {
      const said = await $.process.run([`${$.plugin.root}/bin/wh`, 'stop', String(pid)])
      if (said.exitCode !== 0) $.ui.toast(said.stderr.trim() || `wh stop ${pid} failed with exit ${said.exitCode}`, { timeoutMs: 8000 })
    }
    // One row a run: the label and its rule, then the run, cut at its end on a narrow band so the
    // command gives way first, then the run's Stop button, pressed by a click or by ctrl+x tab and
    // enter. No digit hotkey: a bare digit typed into an empty composer presses a band button, so
    // a prompt that starts "1." would stop a run.
    return (
      <Box flexDirection="column" paddingTop={1}>
        {lines.slice(0, BAND_MAX_RUNS).map((line, at) => (
          <Box flexDirection="row" gap={1}>
            <Box flexShrink={0} flexDirection="row" gap={1}>
              <Text color={BADGE_GREEN} weight="bold">
                {at === 0 ? BAND_LABEL : ' '.repeat(BAND_LABEL.length)}
              </Text>
              <Text color={RULE}>│</Text>
            </Box>
            <Box flexShrink={1}>
              <Text wrap="truncate-end">
                <Text weight="bold">{line.host}</Text>
                <Text dimColor>{` · ${line.time} · ${line.repo} · `}</Text>
                <Text italic>{line.command}</Text>
              </Text>
            </Box>
            {line.pid === null ? null : (
              <Box flexShrink={0}>
                <Button key={`stop:${line.id}`} label="Stop" onPress={() => stop(line.pid as number)} />
              </Box>
            )}
          </Box>
        ))}
        {hidden > 0 ? (
          <Text dimColor italic>
            {`and ${hidden} more ${hidden === 1 ? 'run' : 'runs'}; wh ps lists them`}
          </Text>
        ) : null}
      </Box>
    )
  })

  on('session.start', async ($, e, next) => {
    const path = `${await $.env.get('HOME')}/${LOG}`
    const sessionDir = e.cwd
    const active = new Map<string, Start>()
    // Runs still copying the repository to the workhorse: no synced line yet.
    const copying = new Set<string>()
    let offset: number | undefined
    let checkedAt = 0
    // Redraws the spinner between polls; runs only while a job runs and no copy is counting.
    let spin: Timer | undefined

    // A run whose mirror.sh is gone will never get its end line: drop it. Only a run this session saw
    // going is news; one already gone when the session started was announced by the sessions open then.
    const dropDead = async (nowMs: number, announce: boolean) => {
      if (nowMs - checkedAt < LIVENESS_MS) return
      checkedAt = nowMs
      const tracked = [...active.values()].flatMap(start => (start.pid === undefined ? [] : [{ start, pid: start.pid }]))
      if (tracked.length === 0) return
      const ps = await $.process.run(['ps', '-o', 'pid=,command=', '-p', tracked.map(run => run.pid).join(',')])
      const live = livePids(ps.stdout)
      for (const { start, pid } of tracked) {
        if (live.has(pid)) continue
        active.delete(start.id)
        copying.delete(start.id)
        if (announce) $.ui.toast(`wh ${describe(start)} stopped without reporting how it ended`, { timeoutMs: 8000 })
      }
    }

    const apply = (entries: Entry[], isNew: boolean) => {
      for (const entry of entries) {
        if (entry.event === 'start') {
          if (belongsTo(entry.dir, sessionDir)) {
            active.set(entry.id, entry)
            copying.add(entry.id)
          }
        } else if (entry.event === 'synced') {
          copying.delete(entry.id)
        } else {
          // An end whose start is not tracked belongs to another folder, or started before the tail read.
          const start = active.get(entry.id)
          if (isNew && start !== undefined && deservesToast(start, entry)) $.ui.toast(endToast(start, entry), { timeoutMs: 8000 })
          active.delete(entry.id)
          copying.delete(entry.id)
        }
      }
    }

    const drawBadge = async (nowMs: number) => {
      const text = badgeText(active.values(), copying, nowMs)
      if ((await read($, badge)) !== text) await update($, badge, () => text)
    }

    const show = async (nowMs: number) => {
      const lines = bandLines(active.values(), copying, nowMs / 1000)
      const flat = (rows: RunLines) => rows.map(row => `${row.id} ${row.time}`).join('\n')
      if (flat(await read($, runLines)) !== flat(lines)) await update($, runLines, () => lines)
      await drawBadge(nowMs)
      const spinning = active.size > 0 && copying.size === 0
      if (spinning && spin === undefined) spin = $.clock.every(SPIN_MS, async () => drawBadge(await $.clock.now()))
      if (!spinning && spin !== undefined) {
        spin.cancel()
        spin = undefined
      }
    }

    const poll = async () => {
      // No log yet: everything written to it from now on is new.
      if (!(await $.fs.exists(path))) {
        offset = 0
        await show(await $.clock.now())
        return
      }
      const { size } = await $.fs.stat(path)
      const isFirst = offset === undefined
      // A log shorter than what was read was replaced: read it again from the start.
      let from = offset === undefined || size < offset ? Math.max(0, size - TAIL_BYTES) : offset
      if (size > from) {
        let text = await $.fs.read(path, { offset: from, length: size - from })
        // A tail read can start mid-line; that partial first line is not an entry.
        if (isFirst && from > 0) {
          const partial = text.slice(0, text.indexOf('\n') + 1)
          from += bytes(partial)
          text = text.slice(partial.length)
        }
        // A line still being written has no newline yet; it is read on the next poll.
        const complete = text.slice(0, text.lastIndexOf('\n') + 1)
        apply(parseEntries(complete), !isFirst)
        from += bytes(complete)
      }
      offset = from
      const nowMs = await $.clock.now()
      await dropDead(nowMs, !isFirst)
      await show(nowMs)
    }

    await poll()
    $.clock.every(POLL_MS, poll)
    return next(e)
  })
}
