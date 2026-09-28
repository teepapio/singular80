#!/usr/bin/env node
/**
 * Live monitor for the organigram: how many subagents were spawned, which
 * session is working right now, and what each session finished.
 *
 * Two read-only sources, and nothing else is touched:
 *
 *   1. `~/.local/share/opencode/opencode.db` via `node:sqlite`, opened
 *      read-only. One indexed query per poll gives the whole history:
 *      `session_v2` has `parent_id` (a spawned subagent is a child session),
 *      the `agent` column (which agent ran), `title` (the task), `time_idle`
 *      and `idle_outcome` (how it ended). No writes, no locks, no migration.
 *
 *   2. `GET /api/event` on the local opencode service, an SSE stream. This is
 *      the only signal that says a session is working *right now*: a session
 *      emits events while a turn runs and stops when the turn ends. The
 *      database cannot answer that — `time_updated` is written when a turn
 *      finishes, not while it runs.
 *
 *   `GET /api/session/active` is read as a cross-check only. It reports what
 *   the server believes, and that list keeps entries of runs that never wrote
 *   an idle marker, so it over-counts by a lot (measured: 34 "running"
 *   sessions, of which 29 had not moved for 83 minutes).
 *
 * Usage:
 *   node .opencode/monitor/live.mjs [--port 8791] [--dir /home/edi/singular80]
 *
 * Serves the organigram at `/` and the collected state at `/api/state`.
 */
import { createServer } from 'node:http'
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { DatabaseSync } from 'node:sqlite'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(here, '..', '..')

// ---------------------------------------------------------------- arguments

function arg(name, fallback) {
  const i = process.argv.indexOf(name)
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

const PORT = Number(arg('--port', 8791))
const DIR = arg('--dir', repoRoot)
const HTML = join(here, '..', 'agents-organigramm.html')

/** A session counts as working when it emitted an event this recently. */
const BUSY_MS = 15_000
/** How many finished runs the page shows. */
const RECENT = 12

// ------------------------------------------------------- service + database

/** The local service keeps its password next to its pid; read-only, and the
 *  only credential this monitor needs. */
function service() {
  for (const p of [
    join(process.env.HOME, '.local/state/opencode/service.json'),
    join(process.env.HOME, '.config/opencode/service.json'),
  ]) {
    if (!existsSync(p)) continue
    const s = JSON.parse(readFileSync(p, 'utf8'))
    if (s.url && s.password) return s
  }
  return null
}

const svc = service()
if (!svc) {
  console.error('kein opencode-Dienst gefunden — startet der Server? `opencode service start`')
  process.exit(1)
}
const auth = 'Basic ' + Buffer.from('opencode:' + svc.password).toString('base64')
const api = (path) => fetch(svc.url + path, { headers: { authorization: auth } })

const db = new DatabaseSync(
  join(process.env.HOME, '.local/share/opencode/opencode.db'),
  { readOnly: true },
)

/**
 * The project id this directory belongs to. opencode 2.0.18 keeps an empty
 * `project_directory` table on this machine and files the path in
 * `project.worktree`, so both are tried.
 */
const projectId =
  db
    .prepare('select project_id from project_directory where directory = ? limit 1')
    .get(DIR)?.project_id ??
  db.prepare('select id from project where worktree = ? limit 1').get(DIR)?.id
if (!projectId) {
  console.error(`Projekt für ${DIR} nicht in opencode.db`)
  process.exit(1)
}

// ------------------------------------------------------------- live events

/**
 * sessionID -> { at, kind, label, tool, agent }
 *
 * `at` is the last event that proves work, `label` a one-line description of
 * what the session is doing right now. Reasoning and text deltas are skipped
 * as labels — they change per token and would only flicker — but they still
 * count as activity.
 */
const live = new Map()

const SKIP_LABEL = new Set([
  'session.reasoning.delta',
  'session.reasoning.started',
  'session.usage.updated',
  'server.connected',
  'server.ping',
])

function label(type, d) {
  switch (type) {
    case 'session.tool.input.started':
    case 'session.tool.called': {
      const tool = d.name ?? 'tool'
      const i = d.input ?? {}
      if (tool === 'shell' || tool === 'bash') return `shell: ${(i.command ?? '').split('\n')[0]}`
      if (tool === 'read' || tool === 'edit' || tool === 'write') return `${tool}: ${i.filePath ?? i.path ?? ''}`
      if (tool === 'grep' || tool === 'glob') return `${tool}: ${i.pattern ?? ''}`
      if (tool === 'task' || tool === 'subagent' || tool === 'agent')
        return `spawnt ${i.agent ?? i.subagent_type ?? '?'}: ${(i.description ?? '').slice(0, 60)}`
      return tool
    }
    case 'session.text.delta':
    case 'session.text':
      return `text: ${String(d.text ?? d.content ?? '').trim().slice(0, 60)}`
    case 'session.error':
      return 'Fehler'
    case 'session.idle':
      return 'fertig'
    case 'session.updated':
      return 'aktualisiert'
    case 'session.step.started':
      return 'arbeitet'
    case 'session.step.ended':
      return 'schliesst ab'
    case 'session.step.streamed':
      return 'streamt'
    case 'session.tool.progress':
      return 'Werkzeug laeuft'
    case 'session.tool.success':
      return 'Werkzeug fertig'
    default:
      if (type.includes('reasoning')) return 'denkt nach'
      if (type.startsWith('shell.')) return 'Shell'
      return type.replace(/^session\./, '')
  }
}

function onEvent(e) {
  const d = e.data ?? {}
  const id = d.sessionID
  if (!id) return
  // The stream is global: on this machine it also carries the sessions of the
  // other two projects (measured: `/home/edi` and `/home/edi/endgame`). Only the
  // directory this monitor was started for counts.
  const where = e.location?.directory
  if (where && where !== DIR) return
  const at = e.created ?? Date.now()
  const prev = live.get(id)
  const skip = SKIP_LABEL.has(e.type)
  // A delta counts as activity even when it does not become a label, so an
  // existing entry is only re-stamped. A session seen for the first time
  // still gets one, otherwise a session stuck in a reasoning phase would look
  // idle while it is visibly working.
  if (skip && prev) {
    prev.at = at
    return
  }
  live.set(id, {
    at,
    kind: e.type,
    label: skip ? quietLabel(e.type) : label(e.type, d),
    tool: d.name ?? null,
    agent: d.agent ?? null,
  })
}

/** The label for an event that is too noisy to show but still proves work. */
function quietLabel(type) {
  if (type.startsWith('session.reasoning')) return 'denkt nach'
  if (type.startsWith('session.usage')) return 'verbraucht Tokens'
  if (type.startsWith('server.')) return 'verbunden'
  return type.replace(/^session\./, '')
}

let connected = false
let eventsSeen = 0

async function follow() {
  for (;;) {
    try {
      const res = await api('/api/event')
      if (!res.ok) throw new Error('HTTP ' + res.status)
      connected = true
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buf = ''
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        let cut
        while ((cut = buf.indexOf('\n\n')) >= 0) {
          const frame = buf.slice(0, cut)
          buf = buf.slice(cut + 2)
          for (const line of frame.split('\n')) {
            if (!line.startsWith('data: ')) continue
            try {
              onEvent(JSON.parse(line.slice(6)))
              eventsSeen++
            } catch {
              /* a half-written frame is not worth failing the stream over */
            }
          }
        }
      }
    } catch (err) {
      connected = false
      console.error('SSE getrennt:', err.message, '— neuer Versuch in 3 s')
    }
    await new Promise((r) => setTimeout(r, 3000))
  }
}

// ------------------------------------------------------------ state to send

function sessions() {
  return db
    .prepare(
      `select id, parent_id, agent, title, cost, tokens_input, tokens_output,
              time_created, time_updated, time_idle, idle_outcome
       from session_v2 where project_id = ?`,
    )
    .all(projectId)
}

async function state() {
  const now = Date.now()
  const all = sessions()
  const byId = new Map(all.map((s) => [s.id, s]))

  const spawned = all.filter((s) => s.parent_id)
  const perAgent = {}
  for (const s of spawned) {
    const a = s.agent || '(unbekannt)'
    perAgent[a] = (perAgent[a] ?? 0) + 1
  }

  // Working right now: an event inside the freshness window. A session that
  // the server still calls "active" but that has been silent for minutes is
  // reported separately instead of being drawn as busy.
  const working = []
  for (const [id, l] of live) {
    if (now - l.at > BUSY_MS) continue
    const s = byId.get(id)
    working.push({
      id,
      agent: l.agent ?? s?.agent ?? '?',
      title: s?.title ?? 'unbenannte Sitzung',
      child: Boolean(s?.parent_id),
      label: l.label,
      kind: l.kind,
      since: l.at,
    })
  }
  working.sort((a, b) => a.since - b.since)

  let serverActive = null
  try {
    const res = await api('/api/session/active')
    if (res.ok) serverActive = Object.keys((await res.json()).data ?? {}).length
  } catch {
    serverActive = null
  }

  const recent = all
    .filter((s) => s.parent_id && s.idle_outcome)
    .sort((a, b) => (b.time_idle ?? 0) - (a.time_idle ?? 0))
    .slice(0, RECENT)
    .map((s) => ({
      id: s.id,
      agent: s.agent,
      title: s.title,
      outcome: s.idle_outcome,
      ms: (s.time_idle ?? 0) - (s.time_created ?? 0),
      cost: s.cost ?? 0,
      parent: s.parent_id,
    }))

  return {
    generatedAt: now,
    connected,
    eventsSeen,
    seenSessions: live.size,
    serverActive,
    project: { id: projectId, directory: DIR },
    totals: { sessions: all.length, spawned: spawned.length, mains: all.length - spawned.length },
    perAgent,
    working,
    recent,
  }
}

// ------------------------------------------------------------------- server

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  if (url.pathname === '/api/state') {
    const body = JSON.stringify(await state())
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    return res.end(body)
  }
  if (url.pathname === '/' || url.pathname === '/index.html') {
    const body = readFileSync(HTML)
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
    return res.end(body)
  }
  res.writeHead(404, { 'content-type': 'text/plain' })
  res.end('nicht gefunden\n')
}).listen(PORT, '127.0.0.1', () => {
  console.log(`Organigramm:  http://127.0.0.1:${PORT}/`)
  console.log(`Zustand:      http://127.0.0.1:${PORT}/api/state`)
  console.log(`Projekt:      ${DIR} (${projectId})`)
  follow()
})
