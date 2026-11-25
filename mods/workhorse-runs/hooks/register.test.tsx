// ABOUTME: Tests the workhorse-runs mod against a run log and process table held in memory.
// ABOUTME: Covers which runs show in the footer badge and which earn a toast when their mirror.sh is gone.
import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'
import { BADGE_GREEN, describe } from './register'

const HOME = '/home/alice'
const LOG = `${HOME}/.local/state/workhorse/runs.jsonl`
// The badge's text in any state: copying (↗ wh - gamma 0:02) or the job running (⠋ wh - gamma 0:09).
const BADGE = /^\S wh - [a-z, ]+ \d+:\d\d$/
// The braille spinner's frames, in order, while the job runs.
const FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
const SPINNING = /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] wh - gamma \d+:\d\d$/
const FOOTER = { plugin: 'claude-workhorses', surface: 'terminal', component: 'SessionMode', props: { modes: ['focus'] } } as const

const BAND_PROPS = {
  hasSurvey: false,
  isCollapsed: false,
  isWorking: false,
  maxRows: 10,
  bodyColumns: 100,
  scroll: { offset: 0, bodyRows: 9 },
  view: {},
}

// The run lines the band above the prompt draws now, one per run, top to bottom.
async function bandNow($: Parameters<TestBody>[0], props: Partial<typeof BAND_PROPS> = {}): Promise<string[]> {
  const ui = await $.ui.mount({
    plugin: 'claude-workhorses',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: { ...BAND_PROPS, ...props },
  })
  // Each run is a green bold label ("wh gamma:") followed by its grey italic command, then its repository and time.
  const texts = await ui.findAll({ type: 'Text' })
  await ui.unmount()
  const lines: string[] = []
  texts.forEach((label, at) => {
    if (!/^wh \S+:$/.test(label.text)) return
    const [command, repoAndTime] = [texts[at + 1], texts[at + 2]]
    expect(label.props).toMatchObject({ color: BADGE_GREEN, weight: 'bold' })
    expect(command?.props).toMatchObject({ dimColor: true, italic: true })
    expect(repoAndTime?.props).toMatchObject({ dimColor: true, italic: true })
    lines.push(`${label.text} ${command?.text} ${repoAndTime?.text}`)
  })
  return lines
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
  const state = { log: '', live: new Set<number>(), toasts: [] as string[], status: undefined as string | undefined }
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
    const asked = (e.argv[e.argv.length - 1] ?? '').split(',').map(Number)
    const stdout = asked.filter(pid => state.live.has(pid)).map(pid => `${pid} /bin/bash mirror.sh run gamma\n`).join('')
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
  expect(await badgeNow($)).toBe('↗ wh - gamma 0:10')
  expect(await bandNow($)).toEqual(['wh gamma: sleep 300 (demo) · 0:10'])
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
  expect(await badgeNow($)).toBe('↗ wh - gamma 0:04')

  state.log += `${end('mine', 1003, 3, 'no workhorse is free:')}\n`
  await clock.advance(2_000)

  expect(state.toasts).toEqual(['wh gamma: sleep 300 (fix) ended after 5s, BLOCKED: no workhorse is free:'])
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
  expect((await ui.find({ type: 'Text', text: /^↗ wh/ }))?.text).toBe('↗ wh - gamma 0:02')
  await ui.unmount()

  await clock.advance(63_000)
  ui = await $.ui.mount(FOOTER)
  expect((await ui.find({ type: 'Text', text: /^↗ wh/ }))?.text).toBe('↗ wh - gamma 1:05')
  await ui.unmount()

  state.log += `${synced('live', 1064)}\n`
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  const running = (await ui.find({ type: 'Text', text: BADGE }))?.text
  expect(running).toMatch(SPINNING)
  // The time goes on counting the whole run, copy included.
  expect(running?.slice(2)).toBe('wh - gamma 1:07')
  await ui.unmount()

  // A run that ends before its copy is ready (BLOCKED) takes the badge with it.
  state.log += `${start('blocked', 4248, 1066)}\n${end('live', 1066, 0)}\n`
  state.live.add(4248)
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  expect((await ui.find({ type: 'Text', text: /^↗ wh/ }))?.text).toBe('↗ wh - gamma 0:02')
  await ui.unmount()
  state.log += `${end('blocked', 1068, 3, 'no workhorse is free')}\n`
  await clock.advance(2_000)
  ui = await $.ui.mount(FOOTER)
  expect(await ui.find({ type: 'Text', text: BADGE })).toBeUndefined()
  await ui.unmount()
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
    return text.slice(0, 1)
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
  expect((await ui.find({ type: 'Text', text: BADGE }))?.text).toMatch(/^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] wh - beta, gamma \d+:\d\d$/)
  await ui.unmount()
})

test('the band above the prompt names each run of this folder on its own line, and yields to a survey', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  const state = world(on)
  await $.session.start({ cwd: '/repo/demo', surface: 'terminal', isInteractive: true })

  state.log = [start('a', 4261, 990, '/repo/demo', 'gamma'), synced('a', 995), start('b', 4262, 999, '/repo/demo', 'alpha')].join('\n') + '\n'
  for (const pid of [4261, 4262]) state.live.add(pid)
  await clock.advance(1_000)

  expect(await bandNow($)).toEqual(['wh gamma: sleep 300 (demo) · 0:11', 'wh alpha: sleep 300 (demo) · 0:02'])
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
    'wh gamma: sleep 300 (demo) · 0:10',
    'wh gamma: sleep 300 (demo) · 0:09',
    'wh gamma: sleep 300 (demo) · 0:08',
  ])
  const ui = await $.ui.mount({ plugin: 'claude-workhorses', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })
  expect((await ui.find({ type: 'Text', text: /more/ }))?.text).toBe('and 2 more runs')
  await ui.unmount()
})
