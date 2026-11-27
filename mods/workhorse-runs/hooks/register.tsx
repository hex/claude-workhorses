// ABOUTME: Watches the workhorse run log that mirror.sh writes and shows the wh runs started from this session's folder.
// ABOUTME: While one runs, a green wh badge sits in the prompt footer, its arrows swapping while the copy syncs, then a spinner while the job runs;
// ABOUTME: the band above the prompt names each run with a Stop button, and a toast marks a long or BLOCKED end;
// ABOUTME: /workhorses opens a pane of each workhorse's load and the runs going on it, from wh hosts --json.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { Badge, HostRun, HostView, HostsView, RunLines } from '../types'

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
// Between wh and the host, two arrows swap while the copy syncs the repository to the workhorse, every
// SYNC_MS, and a braille spinner turns while the job itself runs there, every SPIN_MS.
const SYNC_ARROWS = ['⇄', '⇆']
const SYNC_MS = 500
const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
const SPIN_MS = 100
// The band above the prompt is shared with other mods' rows: this mod's row names at most this many
// runs, then counts the rest on one more line.
const BAND_MAX_RUNS = 3
// Powerline half circles (Nerd Fonts) drawn in the green give the badge rounded ends.
const ROUND_LEFT = '\ue0b6'
const ROUND_RIGHT = '\ue0b4'

const badge = atom({ plugin: 'workhorses', key: 'badge' } as const, null as Badge)
const runLines = atom({ plugin: 'workhorses', key: 'runLines' } as const, [] as RunLines, { shape: 'run-lines-2' })
// The band's label, as the claude-bloodhounds band opens its row; later rows keep its width blank.
const BAND_LABEL = '↗ workhorses'
// The grey of the rule between the label and the runs.
const RULE = 'gray'

// pid is the laptop pid of the mirror.sh run; log lines written before it was recorded lack it. session is
// the Claude Code session that started the run, absent for a run started elsewhere or logged before it.
type Start = { event: 'start'; id: string; at: number; host: string; dir: string; command: string; pid?: number; session?: string }
// The copy on the workhorse matches the laptop and the job is starting.
type Synced = { event: 'synced'; id: string; at: number }
// reason: the first line of a BLOCKED message (exit 3), stopped, or one of UNSETTLED_ENDS' keys; absent when
// the command's own exit code ended the run.
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

// Control characters, C1 included, which a terminal would act on rather than show, and the characters that
// reorder or hide text: bidi controls and zero-width characters.
const UNPRINTABLE = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g

function isBlocked(end: End): boolean {
  return end.exit === 3 && end.reason !== undefined
}

// The ends mirror.sh records when a stop or a dropped connection left the job's state on the host in
// question, as the toast words them. A run stopped and confirmed says only "stopped".
const UNSETTLED_ENDS: ReadonlyMap<string, string> = new Map([
  ['stop-unconfirmed', 'stopped here, but the job may still be running on the host'],
  ['lost', 'connection lost, and the job may still be running on the host'],
  ['lost-stopped', 'connection lost, so wh stopped the job on the host'],
])

function unsettled(end: End): string | undefined {
  return end.reason === undefined ? undefined : UNSETTLED_ENDS.get(end.reason)
}

export function deservesToast(start: Start | undefined, end: End): boolean {
  return isBlocked(end) || unsettled(end) !== undefined || (start !== undefined && end.at - start.at >= LONG_RUN_SECONDS)
}

export function endToast(start: Start | undefined, end: End): string {
  const what = start === undefined ? `run ${end.id}` : describe(start)
  const took = start === undefined ? '' : ` after ${duration(end.at - start.at)}`
  // A BLOCKED reason can quote what a host wrote, such as a lock's owner file.
  const result = isBlocked(end) ? `BLOCKED: ${end.reason?.replace(UNPRINTABLE, '')}` : end.reason === 'stopped' ? 'stopped' : (unsettled(end) ?? `exit ${end.exit}`)
  return `wh ${what} ended${took}, ${result}`
}

// Reads `ps -o pid=,command=` output and returns the pids that still belong to a mirror.sh run, by the
// pattern wh ps uses (mirror.sh's live_runs), so a pid that a wh hosts or wh stop now holds is not a run.
export function livePids(psOutput: string): Set<number> {
  const live = new Set<number>()
  for (const line of psOutput.split('\n')) {
    const [, pid, command] = /^\s*(\d+)\s+(.*)$/.exec(line) ?? []
    if (pid !== undefined && command !== undefined && /mirror\.sh run/.test(command)) live.add(Number(pid))
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

// The badge's text: none without a run; else wh, the mark of what the runs do now and the workhorses
// they went to, each once. While any run still copies, the swapping arrows; once every job runs, a
// spinner frame. The band's rows carry each run's time.
export function badgeText(active: Iterable<Start>, copying: ReadonlySet<string>, nowMs: number): Badge {
  const runs = [...active]
  if (runs.length === 0) return null
  const hosts = [...new Set(runs.map(start => start.host))].sort().join(', ')
  if (runs.some(start => copying.has(start.id))) {
    return `wh ${SYNC_ARROWS[Math.floor(nowMs / SYNC_MS) % SYNC_ARROWS.length]} ${hosts}`
  }
  return `wh ${SPINNER[Math.floor(nowMs / SPIN_MS) % SPINNER.length]} ${hosts}`
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

// The /workhorses pane's id. The hooks spell the command out: claude plugin validate counts a command.run hook as
// answering its own command only when the registration and the matcher name it literally.
const PANE_ID = 'workhorses'
// wh hosts gives each host 5 seconds; the rest is jq and margin.
const HOSTS_TIMEOUT_MS = 15_000
// While the pane is on screen (placed, and not a tab behind another pane), its age line moves on every tick
// and wh hosts runs about once a minute. Nothing runs ssh while it is not: this mod loads in every session.
const PANE_TICK_MS = 10_000
const HOSTS_REFRESH_MS = 60_000

// Change the tag when HostsView's type changes: the atom then declines what an earlier version stored.
const hostsView = atom({ plugin: 'workhorses', key: 'hostsView' } as const, { checkedAt: null, hosts: [], error: null } as HostsView, {
  shape: 'hosts-view-1',
})

type Fields = Record<string, unknown>

// Reads one line of wh hosts --json, strictly: an unknown state, a missing or extra field, or a field of the
// wrong type fails, naming the line. Every string comes out as plain text.
function parseHostLine(line: string): HostView {
  const fail = (why: string): never => {
    throw new Error(`wh hosts --json: ${why} in line ${line.replace(UNPRINTABLE, '')}`)
  }
  const fields = (value: unknown, keys: readonly string[]): Fields => {
    if (typeof value !== 'object' || value === null || Array.isArray(value)) return fail('not an object')
    const found = Object.keys(value).sort()
    if (found.join() !== [...keys].sort().join()) return fail('unexpected fields')
    return value as Fields
  }
  const text = (value: unknown): string => (typeof value === 'string' ? value.replace(UNPRINTABLE, '') : fail('a field that is not text'))
  const count = (value: unknown): number =>
    typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : fail('a field that is not a whole number')
  const orNull = <T,>(value: unknown, read: (value: unknown) => T): T | null => (value === null ? null : read(value))
  const run = (value: unknown): HostRun => {
    const doc = fields(value, ['work', 'machine', 'pid', 'since', 'command', 'dir', 'session', 'stoppable'])
    const work = text(doc.work)
    const command = text(doc.command)
    if (doc.stoppable === true) {
      return {
        work,
        machine: text(doc.machine),
        pid: count(doc.pid),
        since: text(doc.since),
        command,
        dir: text(doc.dir),
        session: orNull(doc.session, text),
        stoppable: true,
      }
    }
    if (doc.stoppable !== false || doc.dir !== null || doc.session !== null) return fail('a run that is neither stoppable nor another\'s')
    return {
      work,
      machine: orNull(doc.machine, text),
      pid: orNull(doc.pid, count),
      since: orNull(doc.since, text),
      command,
      dir: null,
      session: null,
      stoppable: false,
    }
  }
  let value: unknown
  try {
    value = JSON.parse(line)
  } catch {
    return fail('not JSON')
  }
  const state = (value as Fields | null)?.state
  if (state === 'unreachable') return { host: text(fields(value, ['host', 'state']).host), state }
  if (state === 'unexpected') {
    const doc = fields(value, ['host', 'state', 'answer'])
    return { host: text(doc.host), state, answer: text(doc.answer) }
  }
  if (state !== 'ok') return fail('unknown state')
  const doc = fields(value, ['host', 'state', 'load', 'cores', 'runs'])
  if (typeof doc.load !== 'number' || !(doc.load >= 0)) return fail('a load that is not a number')
  if (!Array.isArray(doc.runs)) return fail('runs that are not a list')
  return { host: text(doc.host), state, load: doc.load, cores: count(doc.cores), runs: doc.runs.map(run) }
}

// A folder under the home folder as ~/..., a Claude Code worktree's .claude/worktrees/<name> as "⎇ <name>".
function folderLabel(dir: string, home: string): string {
  const under = home !== '' && (dir === home || dir.startsWith(`${home}/`)) ? `~${dir.slice(home.length)}` : dir
  const worktree = /^(.*)\/\.claude\/worktrees\/([^/]+)$/.exec(under)
  return worktree === null ? under : `${worktree[1]} ⎇ ${worktree[2]}`
}

// Whether this Claude Code session (its id, or null when unknown) started the run: by id alone, so another
// session's run from the same folder, or a run started outside Claude Code, is never its own.
function isThisSession(run: HostRun, sessionId: string | null): boolean {
  return sessionId !== null && run.session === sessionId
}

// Where the pane's rows put a run: this session's first, then this laptop's others, then the rest.
function runRank(run: HostRun, sessionId: string | null): number {
  if (!run.stoppable) return 2
  return isThisSession(run, sessionId) ? 0 : 1
}

function hostHeader(host: HostView): string {
  if (host.state === 'unreachable') return `${host.host} · unreachable`
  if (host.state === 'unexpected') return `${host.host} · unexpected answer: ${host.answer}`
  const runs = host.runs.length === 0 ? 'idle' : host.runs.length === 1 ? '1 run' : `${host.runs.length} runs`
  return `${host.host} · load ${host.load.toFixed(2)} of ${host.cores} · ${runs}`
}

// The command leads and the folder or machine comes last, so a row cut at an 80-column pane's edge loses
// where it came from before what it runs.
function runRow(run: HostRun, home: string, sessionId: string | null): string {
  const since = run.since === null ? '' : ` · since ${run.since.slice(11, 16)}`
  const command = runCommand(run) || 'no owner recorded'
  if (run.stoppable) {
    const mine = isThisSession(run, sessionId) ? ' · this session' : ''
    return `${command}${mine}${since} · ${folderLabel(run.dir, home)}`
  }
  return run.machine === null ? `${run.work} · ${command}` : `${command}${since} · from ${run.machine}`
}

// The pane's first line: how old the report is, or why the last refresh failed.
function reportAge(view: HostsView, nowMs: number): string {
  const age = view.checkedAt === null ? null : duration((nowMs - view.checkedAt) / 1000)
  if (view.error !== null) return age === null ? view.error : `${view.error} · hosts as of ${age} ago`
  return age === null ? 'checking…' : `checked ${age} ago`
}

// The pane's refreshes: the one running, if any, and when the last one started, so the timer leaves a
// minute between them. One wh hosts --json at a time: a refresh asked for while one runs waits for that one.
type Refresh = { inFlight: Promise<void> | undefined; startedMs: number }

function refreshHosts($: EngineInterface, refresh: Refresh): Promise<void> {
  refresh.inFlight ??= askHosts($, refresh).finally(() => {
    refresh.inFlight = undefined
  })
  return refresh.inFlight
}

// Runs wh hosts --json and stores its report; a refresh that fails keeps the hosts already shown and says why.
async function askHosts($: EngineInterface, refresh: Refresh): Promise<void> {
  refresh.startedMs = await $.clock.now()
  let hosts: HostView[] | undefined
  let error: string | null = null
  try {
    const ran = await $.process.run([`${$.plugin.root}/bin/wh`, 'hosts', '--json'], { timeoutMs: HOSTS_TIMEOUT_MS })
    if (ran.exitCode !== 0) {
      error = `wh hosts exited ${ran.exitCode}: ${ran.stderr.trim().split('\n')[0] || 'it said nothing'}`
    } else {
      hosts = ran.stdout.split('\n').filter(line => line.trim() !== '').map(parseHostLine)
    }
  } catch (failed) {
    error = (failed as Error).message
  }
  const nowMs = await $.clock.now()
  // stderr and an error's message are as untrusted as the report: plain text, like every other string.
  const said = error?.replace(UNPRINTABLE, '') ?? null
  await update($, hostsView, (view: HostsView): HostsView => (hosts === undefined ? { ...view, error: said } : { checkedAt: nowMs, hosts, error: null }))
}

export const register: Register = on => {
  // The home folder the pane's folders are shown under; session.start sets it.
  let paneHome = ''

  const refresh: Refresh = { inFlight: undefined, startedMs: 0 }

  on('command.run', { command: 'workhorses' }, async $ => {
    const opened = await $.ui.open({ id: PANE_ID, title: 'workhorses' }).catch((error: unknown) => ({ isPlaced: false as const, reason: (error as Error).message }))
    // A pane nobody can see asks no host.
    if (!opened.isPlaced) return { text: `workhorses pane: ${opened.reason}` }
    // The pane is open and shows "checking…" while this runs; $ is not usable once the hook has answered.
    await refreshHosts($, refresh)
    return { text: 'workhorses pane opened.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE_ID }, async ($, e) => {
    const view = await read($, hostsView)
    const nowMs = await $.clock.now()
    // Read at each drawing, since a /clear goes on under a new id without a session.start.
    // Without this session's id no run is marked as this session's; the failure goes to the log.
    const sessionId = await $.session.id().catch((error: unknown) => {
      $.ui.log(`workhorses pane: no session id, so no run is marked this session's: ${(error as Error).message}`)
      return null
    })
    const { Box, Button, Text } = $.ui.resolve(e)
    const stop = async (pid: number) => {
      const said = await $.process.run([`${$.plugin.root}/bin/wh`, 'stop', String(pid)])
      if (said.exitCode !== 0) $.ui.toast(said.stderr.trim() || `wh stop ${pid} failed with exit ${said.exitCode}`, { timeoutMs: 8000 })
      await refreshHosts($, refresh)
    }
    // Busy hosts first, then the rest in the hosts file's order: an inline pane is only so tall.
    const hosts = [...view.hosts].sort((a, b) => Number(a.state !== 'ok' || a.runs.length === 0) - Number(b.state !== 'ok' || b.runs.length === 0))
    // Each row is one Text cut at its end: Texts side by side would wrap into narrow columns. A run's Stop
    // button has no hotkey, as a digit typed into the composer could press it.
    return (
      <Box flexDirection="column">
        <Box flexDirection="row" gap={1}>
          <Box flexShrink={1}>
            <Text wrap="truncate-end" color={view.error === null ? undefined : 'error'} dimColor={view.error === null}>
              {reportAge(view, nowMs)}
            </Text>
          </Box>
          <Box flexShrink={0}>
            <Button key="refresh" label="Refresh" onPress={() => refreshHosts($, refresh)} />
          </Box>
        </Box>
        {/* No blank row between hosts: an inline pane is only so tall. */}
        <Box flexDirection="column" marginTop={1}>
          {hosts.map(host => (
            <Box flexDirection="column">
              <Text wrap="truncate-end" weight="bold">
                {hostHeader(host)}
              </Text>
              {(host.state === 'ok' ? [...host.runs].sort((a, b) => runRank(a, sessionId) - runRank(b, sessionId)) : []).map(run => (
                <Box flexDirection="row" gap={1} paddingLeft={2}>
                  <Box flexShrink={1}>
                    <Text wrap="truncate-end" dimColor={!run.stoppable}>
                      {runRow(run, paneHome, sessionId)}
                    </Text>
                  </Box>
                  {run.stoppable ? (
                    <Box flexShrink={0}>
                      <Button key={`stop:${run.pid}`} label="Stop" onPress={() => stop(run.pid)} />
                    </Box>
                  ) : null}
                </Box>
              ))}
            </Box>
          ))}
        </Box>
      </Box>
    )
  })

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
    paneHome = (await $.env.get('HOME')) ?? ''
    const active = new Map<string, Start>()
    // Runs still copying the repository to the workhorse: no synced line yet.
    const copying = new Set<string>()
    let offset: number | undefined
    let checkedAt = 0
    // Redraws the badge's arrows or spinner between polls, while any run goes; a redraw that changes
    // nothing writes nothing.
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
      const spinning = active.size > 0
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

    // Without /workhorses nothing opens the pane, so the timer starts only once the command is registered.
    try {
      await $.command.register({ name: 'workhorses', description: 'Open the workhorses pane: each workhorse, its load and the wh runs going on it', immediate: true })
      $.clock.every(PANE_TICK_MS, async () => {
        try {
          if (!(await $.ui.panes()).some(pane => pane.id === PANE_ID && pane.isPlaced && pane.isShown)) return
          if ((await $.clock.now()) - refresh.startedMs >= HOSTS_REFRESH_MS) await refreshHosts($, refresh)
          else $.ui.invalidate('ui.render')
        } catch (error) {
          $.ui.log(`workhorses pane: ${(error as Error).message}`)
        }
      })
    } catch (error) {
      $.ui.log(`workhorses: /workhorses is not available: ${(error as Error).message}`)
    }
    return next(e)
  })
}
