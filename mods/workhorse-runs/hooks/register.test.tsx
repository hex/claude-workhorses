// ABOUTME: Tests the workhorse-runs mod against a run log and process table held in memory.
// ABOUTME: Covers which runs show in the footer badge and which earn a toast when their mirror.sh is gone.
import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'
import { BADGE_GREEN, describe } from './register'

const HOME = '/home/alice'
const LOG = `${HOME}/.local/state/workhorse/runs.jsonl`
// The badge's text in any state: copying (wh ⇄ gamma 0:02) or the job running (wh ⠋ gamma 0:09).
const BADGE = /^wh \S [a-z, ]+ \d+:\d\d$/
// The braille spinner's frames, in order, while the job runs.
const FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
// The spinner frame between wh and the hosts, with the space after it.
const SPINNING_MARK = /(?<=^wh )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] /
const SPINNING = /^wh [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] gamma \d+:\d\d$/
const FOOTER = { plugin: 'workhorses', surface: 'terminal', component: 'SessionMode', props: { modes: ['focus'] } } as const

const BAND_PROPS = {
  hasSurvey: false,
  isCollapsed: false,
  isWorking: false,
  maxRows: 10,
  bodyColumns: 100,
  scroll: { offset: 0, bodyRows: 9 },
  view: {},
}

// The run rows the band above the prompt draws now, top to bottom, each as "host · time · repo · command".
// The band opens with the green bold label, as a row of the claude-bloodhounds band does, and every row
// has a Stop button with no hotkey: a digit typed into an empty composer must never stop a run.
async function bandNow($: Parameters<TestBody>[0], props: Partial<typeof BAND_PROPS> = {}): Promise<string[]> {
  const ui = await $.ui.mount({
    plugin: 'workhorses',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: { ...BAND_PROPS, ...props },
  })
  const rows = (await ui.findAll({ type: 'Text' })).filter(text => text.props.wrap === 'truncate-end').map(text => text.text)
  const label = await ui.find({ type: 'Text', text: '↗ workhorses' })
  const stops = await ui.findAll({ type: 'Button' })
  await ui.unmount()
  if (rows.length > 0) expect(label?.props).toMatchObject({ color: BADGE_GREEN, weight: 'bold' })
  expect(stops.map(stop => [stop.props.label, stop.props.hotkey])).toEqual(rows.map(() => ['Stop', undefined]))
  return rows
}

// The badge's text as the footer draws it now, or undefined when it shows none.
async function badgeNow($: Parameters<TestBody>[0]): Promise<string | undefined> {
  const ui = await $.ui.mount(FOOTER)
  const text = (await ui.find({ type: 'Text', text: BADGE }))?.text
  await ui.unmount()
  return text
}

function start(id: string, pid: number, at: number, dir = '/repo/demo', host = 'gamma'): string {
  return JSON.stringify({ event: 'start', id, at, host, dir, sub: '', command: 'sleep 300', pid })
}

function synced(id: string, at: number): string {
  return JSON.stringify({ event: 'synced', id, at })
}

function end(id: string, at: number, exit: number, reason?: string): string {
  return JSON.stringify({ event: 'end', id, at, exit, ...(reason === undefined ? {} : { reason }) })
}

// The log and the live pids are this world's whole state; the test changes them between polls.
function world(on: On) {
  const state = {
    log: '',
    live: new Set<number>(),
    // The command ps shows for a live pid, when it is not a mirror.sh run.
    commands: new Map<number, string>(),
    toasts: [] as string[],
    status: undefined as string | undefined,
    whCalls: [] as string[][],
  }
  mock.env(on, { HOME })
  on('fs.exists', (_, e) => ({ value: e.path === LOG }))
  on('fs.stat', () => ({
    value: { kind: 'file' as const, size: new TextEncoder().encode(state.log).length, mtimeMs: 0, isLink: false },
  }))
  on('fs.read', (_, e) => {
    const bytes = new TextEncoder().encode(state.log)
    const from = e.offset ?? 0
    return { value: new TextDecoder().decode(bytes.slice(from, from + (e.length ?? bytes.length))) }
  })
  on('process.run', (_, e) => {
    if (e.argv[0]?.endsWith('/bin/wh')) {
      state.whCalls.push(e.argv.slice(1))
      const stopped = state.live.delete(Number(e.argv[2]))
      return {
        value: {
          stdout: stopped ? `wh stop: stopped run ${e.argv[2]} on gamma: sleep 300\n` : '',
          stderr: stopped ? '' : `wh stop: no wh run going has the number ${e.argv[2]}; wh ps lists the runs going\n`,
          exitCode: stopped ? 0 : 1,
          isStdoutTruncated: false,
          isStderrTruncated: false,
        },
      }
    }
    const asked = (e.argv[e.argv.length - 1] ?? '').split(',').map(Number)
    const stdout = asked
      .filter(pid => state.live.has(pid))
      .map(pid => `${pid} ${state.commands.get(pid) ?? '/bin/bash mirror.sh run gamma'}\n`)
      .join('')
    return {
      value: { stdout, stderr: '', exitCode: stdout === '' ? 1 : 0, isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('ui.toast', (_, e) => {
    state.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.status', (_, e) => {
    state.status = e.text
    return { value: undefined }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  // Stands for the engine's own drawing of the footer modes.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>focus</Text>
  })
  return state
}

test('a run whose mirror.sh was already gone when the session started is dropped without a toast', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  state.log = `${start('old', 4242, 900)}\n`

  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  await clock.advance(20_000)

  expect(state.toasts).toEqual([])
  expect(await badgeNow($)).toBe(undefined)
})

test('a run seen going whose mirror.sh then dies gets one toast and leaves the badge', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  state.log = `${start('live', 4243, 990)}\n`
  state.live.add(4243)

  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  expect(await badgeNow($)).toBe('wh ⇄ gamma 0:10')
  expect(await bandNow($)).toEqual(['gamma · copying 0:10 · demo · sleep 300'])
  // The engine draws every mod's status line as a warning, so a run never pins one.
  expect(state.status).toBe(undefined)

  state.live.delete(4243)
  await clock.advance(20_000)
  await clock.advance(20_000)

  expect(state.toasts).toEqual(['wh gamma: sleep 300 (demo) stopped without reporting how it ended'])
  expect(await badgeNow($)).toBe(undefined)
  expect(await bandNow($)).toEqual([])
})

test("another folder's runs stay out of the badge and its BLOCKED end raises no toast", async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  state.log = `${start('theirs', 4244, 990, '/repo/other')}\n`
  state.live.add(4244)

  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  expect(await badgeNow($)).toBe(undefined)
  expect(await bandNow($)).toEqual([])

  state.log += `${end('theirs', 1000, 3, 'no workhorse is free:')}\n`
  await clock.advance(5_000)

  expect(state.toasts).toEqual([])
  expect(await badgeNow($)).toBe(undefined)
})

test('a run started in a worktree inside the session folder shows, and its BLOCKED end raises a toast', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  state.live.add(4245)

  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  state.log = `${start('mine', 4245, 998, '/repo/demo/.worktrees/fix')}\n`
  await clock.advance(2_000)
  expect(await badgeNow($)).toBe('wh ⇄ gamma 0:04')

  state.log += `${end('mine', 1003, 3, 'no workhorse is free:')}\n`
  await clock.advance(2_000)

  expect(state.toasts).toEqual(['wh gamma: sleep 300 (fix) ended after 5s, BLOCKED: no workhorse is free:'])
  expect(await badgeNow($)).toBe(undefined)

  // A run BLOCKED after its copy was made, with host text in the reason: an escape sequence, and U+202E,
  // which shows the text after it reversed.
  state.live.add(4247)
  state.log += `${start('later', 4247, 1004, '/repo/demo')}\n${synced('later', 1005)}\n`
  await clock.advance(2_000)
  expect(await badgeNow($)).toMatch(SPINNING)
  state.log += `${end('later', 1007, 3, 'gamma:~/work/demo is in use by another run: lap\u001b[2J‮ lave')}\n`
  await clock.advance(2_000)

  expect(state.toasts.slice(1)).toEqual(['wh gamma: sleep 300 (demo) ended after 3s, BLOCKED: gamma:~/work/demo is in use by another run: lap[2J lave'])
  expect(await badgeNow($)).toBe(undefined)
})

test('a folder that only shares a name prefix with the session folder is not its own', async ($, on) => {
  mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  state.log = `${start('near', 4246, 990, '/repo/demo-two')}\n`
  state.live.add(4246)

  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  expect(await badgeNow($)).toBe(undefined)
})

test('a leading gtimeout or timeout and its options stay out of the run description', () => {
  const run = (command: string) =>
    describe({ host: 'gamma', dir: '/repo/demo', command })
  expect(run('gtimeout 1800 bash tests/run.sh isolation')).toBe('gamma: bash tests/run.sh isolation (demo)')
  expect(run('gtimeout 30m pnpm test')).toBe('gamma: pnpm test (demo)')
  expect(run('timeout -k 10 1.5h cargo test')).toBe('gamma: cargo test (demo)')
  expect(run('gtimeout --signal=INT --preserve-status 20m make')).toBe('gamma: make (demo)')
  expect(run('pnpm test --timeout 30')).toBe('gamma: pnpm test --timeout 30 (demo)')
  expect(run('gtimeout')).toBe('gamma: gtimeout (demo)')
  // A script passed to sh -c spans lines; it reads as one.
  expect(run('sh -c cd probe && {\n  find . -print\n} >/tmp/out')).toBe('gamma: sh -c cd probe && { find . -print } >/tmp/out (demo)')
})

test('while a run from this folder is going, a green wh badge sits before the footer modes', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)

  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  let ui = await $.ui.mount(FOOTER)
  expect(await ui.find({ type: 'Text', text: BADGE })).toBeUndefined()
  await ui.unmount()

  state.log = `${start('live', 4247, 999)}\n${synced('live', 1000)}\n`
  state.live.add(4247)
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  const badge = await ui.find({ type: 'Text', text: BADGE })
  expect(badge?.text).toMatch(SPINNING)
  // The theme's own green, the one behind the session-name tag, so light and dark themes both carry it.
  expect(BADGE_GREEN).toBe('green_FOR_SUBAGENTS_ONLY')
  // Powerline half circles in the green round the badge's ends.
  expect((await ui.find({ type: 'Text', text: '\ue0b6' }))?.props).toMatchObject({ color: BADGE_GREEN })
  expect((await ui.find({ type: 'Text', text: '\ue0b4' }))?.props).toMatchObject({ color: BADGE_GREEN })
  expect(badge?.props).toMatchObject({ color: 'white', weight: 'bold', backgroundColor: BADGE_GREEN })
  expect(await ui.find({ type: 'Text', text: 'focus' })).toBeDefined()
  await ui.unmount()

  state.log += `${end('live', 1002, 0)}\n`
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  expect(await ui.find({ type: 'Text', text: BADGE })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'focus' })).toBeDefined()
  await ui.unmount()
})

test('while a run copies the repository to the workhorse, the badge counts the copy; when the job starts a spinner takes its place', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  state.log = `${start('live', 4247, 999)}\n`
  state.live.add(4247)
  await clock.advance(1_000)
  let ui = await $.ui.mount(FOOTER)
  expect((await ui.find({ type: 'Text', text: /^wh [⇄⇆]/ }))?.text).toBe('wh ⇄ gamma 0:02')
  await ui.unmount()

  await clock.advance(63_000)
  ui = await $.ui.mount(FOOTER)
  expect((await ui.find({ type: 'Text', text: /^wh [⇄⇆]/ }))?.text).toBe('wh ⇄ gamma 1:05')
  await ui.unmount()

  state.log += `${synced('live', 1064)}\n`
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  const running = (await ui.find({ type: 'Text', text: BADGE }))?.text
  expect(running).toMatch(SPINNING)
  // The time goes on counting the whole run, copy included.
  expect(running?.replace(SPINNING_MARK, '')).toBe('wh gamma 1:07')
  await ui.unmount()

  // A run that ends before its copy is ready (BLOCKED) takes the badge with it.
  state.log += `${start('blocked', 4248, 1066)}\n${end('live', 1066, 0)}\n`
  state.live.add(4248)
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  expect((await ui.find({ type: 'Text', text: /^wh [⇄⇆]/ }))?.text).toBe('wh ⇄ gamma 0:02')
  await ui.unmount()
  state.log += `${end('blocked', 1068, 3, 'no workhorse is free')}\n`
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  expect(await ui.find({ type: 'Text', text: BADGE })).toBeUndefined()
  await ui.unmount()
})

test('while the copy runs, the arrows between wh and the host swap every 500 ms', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  state.log = `${start('live', 4247, 999)}\n`
  state.live.add(4247)
  await clock.advance(1_000)

  const seen = []
  for (let step = 0; step < 4; step++) {
    seen.push(await badgeNow($))
    await clock.advance(500)
  }
  // The time rounds to the nearest second: 2.5 s reads 0:03.
  expect(seen).toEqual(['wh ⇄ gamma 0:02', 'wh ⇆ gamma 0:03', 'wh ⇄ gamma 0:03', 'wh ⇆ gamma 0:04'])
})

test('while the job runs, the spinner steps to its next frame every 100 ms and wraps around', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  state.log = `${start('live', 4247, 999)}\n${synced('live', 1000)}\n`
  state.live.add(4247)
  await clock.advance(1_000)

  const frame = async () => {
    const ui = await $.ui.mount(FOOTER)
    const text = (await ui.find({ type: 'Text', text: BADGE }))?.text ?? ''
    await ui.unmount()
    return text.charAt(3)
  }
  const first = FRAMES.indexOf(await frame())
  expect(first).toBeGreaterThanOrEqual(0)
  const seen = []
  for (let step = 1; step <= FRAMES.length; step++) {
    await clock.advance(100)
    seen.push(await frame())
  }
  expect(seen).toEqual([...FRAMES.slice(first + 1), ...FRAMES.slice(0, first + 1)])
})

test('the badge names the workhorse each run went to, every host once', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  state.log = [
    start('a', 4251, 999, '/repo/demo', 'gamma'),
    synced('a', 1000),
    start('b', 4252, 999, '/repo/demo', 'beta'),
    synced('b', 1000),
    start('c', 4253, 999, '/repo/demo', 'gamma'),
    synced('c', 1000),
  ].join('\n') + '\n'
  for (const pid of [4251, 4252, 4253]) state.live.add(pid)
  await clock.advance(1_000)
  const ui = await $.ui.mount(FOOTER)
  expect((await ui.find({ type: 'Text', text: BADGE }))?.text).toMatch(/^wh [⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] beta, gamma \d+:\d\d$/)
  await ui.unmount()
})

test('the band above the prompt names each run of this folder on its own line, and yields to a survey', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  state.log = [start('a', 4261, 990, '/repo/demo', 'gamma'), synced('a', 995), start('b', 4262, 999, '/repo/demo', 'alpha')].join('\n') + '\n'
  for (const pid of [4261, 4262]) state.live.add(pid)
  await clock.advance(1_000)

  expect(await bandNow($)).toEqual(['gamma · 0:11 · demo · sleep 300', 'alpha · copying 0:02 · demo · sleep 300'])
  expect(await bandNow($, { hasSurvey: true })).toEqual([])
})

test('the band row stays three runs tall, so the rows of other mods keep their room', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  state.log = [1, 2, 3, 4, 5].map(n => start(`r${n}`, 4270 + n, 990 + n)).join('\n') + '\n'
  for (const n of [1, 2, 3, 4, 5]) state.live.add(4270 + n)
  await clock.advance(1_000)

  expect(await bandNow($)).toEqual([
    'gamma · copying 0:10 · demo · sleep 300',
    'gamma · copying 0:09 · demo · sleep 300',
    'gamma · copying 0:08 · demo · sleep 300',
  ])
  const ui = await $.ui.mount({ plugin: 'workhorses', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })
  expect((await ui.find({ type: 'Text', text: /more/ }))?.text).toBe('and 2 more runs; wh ps lists them')
  await ui.unmount()
})

test("a run's Stop button runs wh stop for that run, and a stop that fails says why in a toast", async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  state.log = [start('a', 4261, 990), synced('a', 995), start('b', 4262, 999), synced('b', 999)].join('\n') + '\n'
  for (const pid of [4261, 4262]) state.live.add(pid)
  await clock.advance(1_000)

  const band = await $.ui.mount({ plugin: 'workhorses', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })
  await band.press({ key: 'stop:b' })
  expect(state.whCalls).toEqual([['stop', '4262']])
  expect(state.toasts).toEqual([])

  // The run ended between the drawing and the press.
  state.live.delete(4261)
  await band.press({ key: 'stop:a' })
  await band.unmount()
  expect(state.whCalls).toEqual([['stop', '4262'], ['stop', '4261']])
  expect(state.toasts).toEqual(['wh stop: no wh run going has the number 4261; wh ps lists the runs going'])
})

test('a run whose pid now belongs to another wh command, such as wh hosts, is dropped as gone', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  state.log = `${start('reused', 4270, 990)}\n`
  state.live.add(4270)

  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })
  expect(await badgeNow($)).toBe('wh ⇄ gamma 0:10')

  state.commands.set(4270, '/bin/bash /plugin/scripts/mirror.sh hosts --json')
  await clock.advance(20_000)
  await clock.advance(20_000)

  expect(state.toasts).toEqual(['wh gamma: sleep 300 (demo) stopped without reporting how it ended'])
  expect(await badgeNow($)).toBe(undefined)
})

test('a quick run whose stop the host did not confirm, or whose connection dropped, ends with a toast that says so', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  for (const pid of [4271, 4272, 4273, 4274]) state.live.add(pid)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  state.log = [start('a', 4271, 998), start('b', 4272, 998), start('c', 4273, 998), start('d', 4274, 998)].join('\n') + '\n'
  await clock.advance(1_000)
  state.log += [end('a', 1003, 143, 'stop-unconfirmed'), end('b', 1003, 255, 'lost'), end('c', 1003, 255, 'lost-stopped'), end('d', 1003, 143, 'stopped')].join('\n') + '\n'
  await clock.advance(1_000)

  expect(state.toasts).toEqual([
    'wh gamma: sleep 300 (demo) ended after 5s, stopped here, but the job may still be running on the host',
    'wh gamma: sleep 300 (demo) ended after 5s, connection lost, and the job may still be running on the host',
    'wh gamma: sleep 300 (demo) ended after 5s, connection lost, so wh stopped the job on the host',
  ])
})
