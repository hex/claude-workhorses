// ABOUTME: Tests the /workhorses pane against what wh hosts --json prints, held in memory: each host's load and runs,
// ABOUTME: Stop and Refresh, a failing report, and that no wh hosts runs while the pane is not on screen.
import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

const HOME = '/home/alice'
const SESSION = '/home/alice/proj'
const NOW = Date.parse('2026-11-26T14:00:00Z')
// This Claude Code session's id, as $.session.id() answers it.
const SESSION_ID = 'sess-a1'

const TYPED = { command: 'workhorses', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } } as const

const PANE = {
  plugin: 'workhorses',
  surface: 'terminal',
  component: 'Pane',
  requestId: 'workhorses',
  props: { title: 'workhorses', isFocused: false, bodyColumns: 76, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

type Doc = Record<string, unknown>

function run(overrides: Doc = {}): Doc {
  return { work: 'w-1', machine: null, pid: null, since: null, command: '', dir: null, session: null, stoppable: false, ...overrides }
}

// A report of three hosts: xur with one run of this session, one of another session and folder on this laptop and one
// from another Mac; cayde idle; eris unreachable. The file order puts cayde first.
const REPORT = [
  { host: 'cayde', state: 'ok', load: 0.1, cores: 6, runs: [] },
  {
    host: 'xur',
    state: 'ok',
    load: 2.58,
    cores: 6,
    runs: [
      run({ work: 'house-1', machine: 'erp-mac', pid: 3800, since: '2026-11-26 15:10:00', command: 'make lint', dir: `${HOME}/house`, session: 'sess-b2', stoppable: true }),
      run({ work: 'other-2', machine: 'other-mac', pid: 412, since: '2026-11-26 09:05:01', command: 'make test' }),
      run({
        work: 'ai-batch-3',
        machine: 'erp-mac',
        pid: 3875,
        since: '2026-11-26 15:53:42',
        command: 'gtimeout 45m mise exec node@26 -- npm test',
        dir: `${SESSION}/.claude/worktrees/ai-batch`,
        session: SESSION_ID,
        stoppable: true,
      }),
    ],
  },
  { host: 'eris', state: 'unreachable' },
]

function jsonLines(hosts: readonly Doc[]): string {
  return hosts.map(host => `${JSON.stringify(host)}\n`).join('')
}

// What wh hosts --json and wh stop answer, and which panes the engine lists, are this world's whole state.
function world(on: On) {
  const state = {
    hosts: { stdout: jsonLines(REPORT), stderr: '', exitCode: 0 },
    stop: { stdout: '', stderr: '', exitCode: 0 },
    whCalls: [] as string[][],
    registered: [] as string[],
    opened: [] as string[],
    placed: { isPlaced: true } as { isPlaced: true } | { isPlaced: false; reason: string },
    panes: [] as { id: string; title: string; isShown: boolean; isFocused: boolean; isPlaced: boolean }[],
    toasts: [] as string[],
    logs: [] as string[],
  }
  mock.env(on, { HOME })
  on('fs.exists', () => ({ value: false }))
  on('process.run', (_, e) => {
    const answer = (said: { stdout: string; stderr: string; exitCode: number }) => ({
      value: { ...said, isStdoutTruncated: false, isStderrTruncated: false },
    })
    if (!e.argv[0]?.endsWith('/bin/wh')) return answer({ stdout: '', stderr: '', exitCode: 1 })
    state.whCalls.push(e.argv.slice(1))
    return answer(e.argv[1] === 'hosts' ? state.hosts : state.stop)
  })
  on('command.register', (_, e) => {
    state.registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('ui.open', (_, e) => {
    state.opened.push(e.id)
    return { value: state.placed }
  })
  on('ui.panes', () => ({ value: state.panes }))
  on('ui.toast', (_, e) => {
    state.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', (_, e) => {
    state.logs.push(e.text)
    return { value: undefined }
  })
  on('session.id', () => ({ value: SESSION_ID }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  return state
}

// The pane as $.ui.panes() lists it: placed or waiting undrawn, and shown or a tab behind another pane.
function placed(state: ReturnType<typeof world>, isPlaced: boolean, isShown = isPlaced) {
  state.panes = [{ id: 'workhorses', title: 'workhorses', isShown, isFocused: false, isPlaced }]
}

// The pane's rows, top to bottom, and the label and key of each button it draws.
async function paneNow($: Parameters<TestBody>[0]): Promise<{ rows: string[]; buttons: string[] }> {
  const ui = await $.ui.mount(PANE)
  const rows = (await ui.findAll({ type: 'Text' })).filter(text => text.props.wrap === 'truncate-end').map(text => text.text)
  const buttons = (await ui.findAll({ type: 'Button' })).map(button => `${button.props.label} ${button.key} ${button.props.hotkey ?? ''}`.trim())
  await ui.unmount()
  return { rows, buttons }
}

async function start($: Parameters<TestBody>[0]) {
  await $.session.start({ cwd: SESSION, surface: 'terminal', isInteractive: true })
}

test('/workhorses opens the pane and draws each host with its runs, busy hosts and this session first', async ($, on) => {
  mock.clock(on, { now: NOW })
  const state = world(on)
  await start($)
  expect(state.registered).toEqual(['workhorses'])
  expect(state.opened).toEqual([])
  expect(state.whCalls).toEqual([])

  expect(await $.command.run(TYPED)).toEqual({ text: 'workhorses pane opened.' })
  expect(state.opened).toEqual(['workhorses'])
  expect(state.whCalls).toEqual([['hosts', '--json']])

  expect(await paneNow($)).toEqual({
    rows: [
      'checked 0s ago',
      'xur · load 2.58 of 6 · 3 runs',
      '~/proj ⎇ ai-batch · this session · since 15:53 · mise exec node@26 -- npm test',
      '~/house · since 15:10 · make lint',
      'from other-mac · since 09:05 · make test',
      'cayde · load 0.10 of 6 · idle',
      'eris · unreachable',
    ],
    buttons: ['Refresh refresh', 'Stop stop:3875', 'Stop stop:3800'],
  })
})

test('/workhorses says why when the surface does not place the pane, and asks no host', async ($, on) => {
  mock.clock(on, { now: NOW })
  const state = world(on)
  await start($)
  state.placed = { isPlaced: false, reason: 'no-surface' }

  expect(await $.command.run(TYPED)).toEqual({ text: 'workhorses pane: no-surface' })
  expect(state.whCalls).toEqual([])
})

test('the timer runs wh hosts only while the pane is on screen, once a minute', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const state = world(on)
  await start($)

  await clock.advance(180_000)
  placed(state, false)
  await clock.advance(180_000)
  // Placed, but a tab behind another pane.
  placed(state, true, false)
  await clock.advance(180_000)
  expect(state.whCalls).toEqual([])

  placed(state, true)
  await clock.advance(10_000)
  expect(state.whCalls).toEqual([['hosts', '--json']])
  await clock.advance(50_000)
  expect(state.whCalls).toEqual([['hosts', '--json']])
  // Between refreshes the age moves on.
  expect((await paneNow($)).rows[0]).toBe('checked 50s ago')
  await clock.advance(10_000)
  expect(state.whCalls).toEqual([['hosts', '--json'], ['hosts', '--json']])

  state.panes = []
  await clock.advance(180_000)
  expect(state.whCalls.length).toBe(2)
  expect(state.logs).toEqual([])
})

test('a failing wh hosts shows its error and keeps the hosts it last reported, with their age', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const state = world(on)
  await start($)
  await $.command.run(TYPED)
  await clock.advance(30_000)

  state.hosts = { stdout: '', stderr: 'workhorses: no hosts file at /x/hosts\nsecond line\n', exitCode: 2 }
  const ui = await $.ui.mount(PANE)
  await ui.press({ key: 'refresh' })
  await ui.unmount()
  let rows = (await paneNow($)).rows
  expect(rows[0]).toBe('wh hosts exited 2: workhorses: no hosts file at /x/hosts · hosts as of 30s ago')
  expect(rows[1]).toBe('xur · load 2.58 of 6 · 3 runs')

  state.hosts = { stdout: `${JSON.stringify({ host: 'xur', state: 'busy' })}\n`, stderr: '', exitCode: 0 }
  placed(state, true)
  await clock.advance(60_000)
  rows = (await paneNow($)).rows
  expect(rows[0]).toBe('wh hosts --json: unknown state in line {"host":"xur","state":"busy"} · hosts as of 1m30s ago')
  expect(rows[1]).toBe('xur · load 2.58 of 6 · 3 runs')

  state.hosts = { stdout: jsonLines([{ host: 'cayde', state: 'unreachable', extra: 1 }]), stderr: '', exitCode: 0 }
  await clock.advance(60_000)
  expect((await paneNow($)).rows[0]).toBe(
    'wh hosts --json: unexpected fields in line {"host":"cayde","state":"unreachable","extra":1} · hosts as of 2m30s ago',
  )

  state.hosts = { stdout: jsonLines([{ host: 'cayde', state: 'unreachable' }]), stderr: '', exitCode: 0 }
  await clock.advance(60_000)
  expect((await paneNow($)).rows).toEqual(['checked 0s ago', 'cayde · unreachable'])
  expect(state.logs).toEqual([])
})

test('what a host sent reaches the pane as plain text', async ($, on) => {
  mock.clock(on, { now: NOW })
  const state = world(on)
  state.hosts = {
    stdout: jsonLines([
      { host: 'odd', state: 'unexpected', answer: 'Last login \u001b[1mtoday\u009b2J\u0007' },
      { host: 'xur', state: 'ok', load: 1, cores: 6, runs: [run({ machine: 'other\u001b]0;x', pid: 1, since: '2026-11-26 15:00:00', command: 'make\u0000 \u001b[31mred' })] },
    ]),
    stderr: '',
    exitCode: 0,
  }
  await start($)
  await $.command.run(TYPED)

  expect((await paneNow($)).rows).toEqual([
    'checked 0s ago',
    'xur · load 1.00 of 6 · 1 run',
    'from other]0;x · since 15:00 · make [31mred',
    'odd · unexpected answer: Last login [1mtoday2J',
  ])
})

test("a run's Stop runs wh stop for its pid, a failure says why in a toast, and the hosts are asked again", async ($, on) => {
  mock.clock(on, { now: NOW })
  const state = world(on)
  await start($)
  await $.command.run(TYPED)

  const ui = await $.ui.mount(PANE)
  await ui.press({ key: 'stop:3875' })
  expect(state.whCalls).toEqual([['hosts', '--json'], ['stop', '3875'], ['hosts', '--json']])
  expect(state.toasts).toEqual([])

  state.stop = { stdout: '', stderr: 'wh stop: no wh run going has the number 3800; wh ps lists the runs going\n', exitCode: 1 }
  await ui.press({ key: 'stop:3800' })
  await ui.unmount()
  expect(state.whCalls.slice(3)).toEqual([['stop', '3800'], ['hosts', '--json']])
  expect(state.toasts).toEqual(['wh stop: no wh run going has the number 3800; wh ps lists the runs going'])
})

test('only a run this Claude Code session started is marked, not another run from the same folder', async ($, on) => {
  mock.clock(on, { now: NOW })
  const state = world(on)
  const laptopRun = (pid: number, session: string | null) =>
    run({ work: `proj-${pid}`, machine: 'erp-mac', pid, since: '2026-11-26 10:00:00', command: `make ${pid}`, dir: SESSION, session, stoppable: true })
  state.hosts = {
    stdout: jsonLines([{ host: 'xur', state: 'ok', load: 1, cores: 6, runs: [laptopRun(3, null), laptopRun(2, 'sess-b2'), laptopRun(1, SESSION_ID)] }]),
    stderr: '',
    exitCode: 0,
  }
  await start($)
  await $.command.run(TYPED)

  expect((await paneNow($)).rows).toEqual([
    'checked 0s ago',
    'xur · load 1.00 of 6 · 3 runs',
    '~/proj · this session · since 10:00 · make 1',
    '~/proj · since 10:00 · make 3',
    '~/proj · since 10:00 · make 2',
  ])
})
