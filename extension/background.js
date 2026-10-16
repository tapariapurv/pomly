// Joins a Pomly sync space like any other device (Firebase REST, anonymous auth), streams its timer state,
// and turns site blocking on and off with declarativeNetRequest rules, which keep working while this worker sleeps.
import { REF, ALLOW_MIN, settings, endMs, left, blocking, pattern, site } from './shared.js'

const KEY = 'AIzaSyCBlZMzIfz72TEyqZg-YvqGgIVimYkNRUU' // public by design; the database rules do the guarding (same as Shared/Sync.swift)
const DB = 'https://pomly-43c42-default-rtdb.firebaseio.com'
const ME = 'ext-' + crypto.randomUUID()
const BLOCKED = chrome.runtime.getURL('blocked.html')
let token, expiry = 0, stream, heard = 0

const local = keys => chrome.storage.local.get(keys)

async function auth() {
  if (token && expiry > Date.now()) return token
  const { refresh } = await local('refresh')
  const r = await fetch(refresh ? `https://securetoken.googleapis.com/v1/token?key=${KEY}` : `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': refresh ? 'application/x-www-form-urlencoded' : 'application/json' },
    body: refresh ? `grant_type=refresh_token&refresh_token=${refresh}` : '{"returnSecureToken":true}'
  })
  const j = await r.json().catch(() => ({}))
  const t = j.idToken ?? j.id_token
  if (!t) {
    if (r.status === 400) await chrome.storage.local.remove('refresh') // account gone: start over next time
    throw Error('auth')
  }
  token = t
  expiry = Date.now() + ((+(j.expiresIn ?? j.expires_in) || 3600) - 120) * 1000
  await chrome.storage.local.set({ uid: j.localId ?? j.user_id, refresh: j.refreshToken ?? j.refresh_token })
  return t
}

async function call(path, method = 'GET', body) {
  const r = await fetch(`${DB}/${path}.json?auth=${await auth()}`, { method, body: body === undefined ? undefined : JSON.stringify(body) })
  if (!r.ok) throw Error(r.status)
  return r.json()
}

// MARK: Pairing

async function pair(code) {
  await auth()
  const { uid, space } = await local(['uid', 'space'])
  const c = await call(`codes/${code}`).catch(() => null)
  if (!c || c.exp < Date.now()) throw Error('code')
  if (c.space === space) return
  await leave()
  await call(`spaces/${c.space}/members/${uid}`, 'PUT', code)
  await chrome.storage.local.set({ space: c.space })
  listen()
}

async function leave() {
  const { uid, space } = await local(['uid', 'space'])
  stream?.abort()
  stream = null
  await chrome.storage.local.remove(['space', 'wire'])
  if (space) call(`spaces/${space}/members/${uid}`, 'DELETE').catch(() => {})
}

// MARK: Incoming

async function listen() {
  stream?.abort()
  const { space } = await local('space')
  if (!space) return
  const ctl = stream = new AbortController()
  heard = Date.now()
  const ping = setInterval(() => chrome.runtime.getPlatformInfo(), 20e3) // an extension API call keeps the worker alive while the stream is open
  try {
    const r = await fetch(`${DB}/spaces/${space}/state.json?auth=${await auth()}`, { headers: { Accept: 'text/event-stream' }, signal: ctl.signal })
    if (r.status === 401) return lost()
    const reader = r.body.pipeThrough(new TextDecoderStream()).getReader()
    let buf = '', event = ''
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      heard = Date.now()
      const lines = (buf + value).split('\n')
      buf = lines.pop()
      for (const l of lines) {
        if (l.startsWith('event:')) event = l.slice(6).trim()
        else if (!l.startsWith('data:')) continue
        else if (event === 'put' || event === 'patch') await got(event, JSON.parse(l.slice(5)), space)
        else if (event === 'auth_revoked') expiry = 0 // the stream closes; reconnect with a fresh token
        else if (event === 'cancel') return lost()
      }
    }
  } catch {} finally { clearInterval(ping) }
  if (stream === ctl) setTimeout(listen, 2000)
}

async function got(event, { path, data }, space) {
  // The apps always PUT the whole state, so a partial update is rare: just refetch it.
  const wire = path === '/' && event === 'put' ? data : await call(`spaces/${space}/state`).catch(() => undefined)
  if (wire !== undefined) await chrome.storage.local.set({ wire }) // storage.onChanged applies it
}

/// The rules no longer let us read the space (removed from it).
async function lost() {
  stream = null
  await chrome.storage.local.remove(['space', 'wire'])
}

// MARK: Outgoing

async function control(op) {
  const { wire, space } = await local(['wire', 'space'])
  if (!wire?.s || !space) return
  const s = { ...wire.s }, now = Date.now() / 1000 - REF
  if (op === 'start') Object.assign(s, { status: 'running', remaining: s.planned, startedAt: now, endDate: now + s.planned })
  else if (op === 'pause' && s.status === 'running') { Object.assign(s, { status: 'paused', remaining: left(s) }); delete s.endDate }
  else if (op === 'resume' && s.status === 'paused') Object.assign(s, { status: 'running', endDate: now + s.remaining })
  else if (op === 'stop') {
    const done = s.planned - left(s)
    if (s.phase === 'focus' && (s.status === 'running' || s.status === 'paused') && done >= 60 && s.startedAt != null) {
      const start = s.startedAt + REF // same key as the apps' Session.key, so nobody logs it twice
      call(`spaces/${space}/sessions/${Math.round(start * 1000)}`, 'PUT', { start, duration: done, planned: s.planned, label: s.label, completed: false }).catch(() => {})
    }
    for (const k of ['endDate', 'startedAt']) delete s[k]
    Object.assign(s, { phase: 'focus', status: 'idle', planned: s.phase === 'focus' ? s.planned : 1500, remaining: 0 })
  } else return
  const next = { s, by: ME, at: Date.now() / 1000 }
  await chrome.storage.local.set({ wire: next })
  await call(`spaces/${space}/state`, 'PUT', next)
}

// MARK: Blocking

async function allow(d) {
  const { allow = {} } = await local('allow')
  await chrome.storage.local.set({ allow: { ...allow, [d]: Date.now() + ALLOW_MIN * 60e3 } })
  await apply()
}

// One at a time: overlapping runs would add the same rule ids twice.
let queue = Promise.resolve()
const apply = () => queue = queue.then(applyNow, applyNow)

async function applyNow() {
  const l = await local(['wire', 'space', 'allow']), o = await settings(), on = blocking(l, o), s = l.wire?.s
  const allowed = Object.values(l.allow ?? {}).filter(t => t > Date.now())
  const sites = o.sites.filter(d => !(l.allow?.[d] > Date.now()))
  const old = await chrome.declarativeNetRequest.getDynamicRules()
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: old.map(r => r.id),
    addRules: on ? sites.map((d, i) => ({
      id: i + 1,
      priority: 1,
      action: { type: 'redirect', redirect: { regexSubstitution: `${BLOCKED}#\\0` } },
      condition: { regexFilter: pattern(d), resourceTypes: ['main_frame'] }
    })) : []
  })
  await chrome.alarms.clear('end')
  const next = Math.min(on && s.status === 'running' ? endMs(s) : Infinity, ...(on ? allowed : []))
  if (next < Infinity) chrome.alarms.create('end', { when: next })
  chrome.action.setBadgeBackgroundColor({ color: '#B85A1E' })
  chrome.action.setBadgeText({ text: !on ? '' : s.status === 'paused' ? 'II' : `${Math.ceil(left(s) / 60)}m` })
  if (!on) return
  // Tabs already open on a blocked site switch over too.
  const hit = u => { try { const h = new URL(u).hostname; return !!site(h, sites) } catch { return false } }
  for (const t of await chrome.tabs.query({ url: ['http://*/*', 'https://*/*'] })) if (hit(t.url)) chrome.tabs.update(t.id, { url: `${BLOCKED}#${t.url}` })
}

chrome.storage.onChanged.addListener((c, area) => { if (area === 'sync' || c.wire || c.space || c.allow) apply() })
chrome.alarms.onAlarm.addListener(a => {
  if (a.name === 'tick' && heard < Date.now() - 45e3) listen() // Firebase sends a keep-alive every 30 s, so a quiet stream is a dead one
  apply()
})
chrome.alarms.create('tick', { periodInMinutes: 0.5 })
chrome.runtime.onMessage.addListener((m, _, reply) => {
  const job = m.pair ? pair(m.pair) : m.leave ? leave() : m.allow ? allow(m.allow) : control(m.control)
  job.then(() => reply({ ok: true }), e => reply({ error: e.message }))
  return true
})
listen() // every worker start (browser launch, wake-up) reopens the stream; its first event carries everything missed
