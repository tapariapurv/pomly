const $ = id => document.getElementById(id)
const send = m => ext.runtime.sendMessage(m)
let l = {}, o = {}

async function render() {
  [l, o] = [await ext.storage.local.get(['wire', 'space']), await settings()]
  $('unpaired').hidden = !!l.space
  $('paired').hidden = !l.space
  const s = l.wire?.s, on = blocking(l, o)
  $('pill').textContent = !l.space ? 'Not Paired' : on ? 'Blocking' : 'Paired'
  $('pill').classList.toggle('on', on)
  if (!l.space) return
  $('phase').textContent = s?.phase === 'rest' ? 'Break' : 'Focus'
  $('state').textContent = !s ? 'Connecting…' : on ? (s.status === 'paused' ? 'Paused. Sites stay blocked.' : 'Distracting sites are blocked.')
    : s.status === 'running' ? 'Break time. Browse freely.' : o.enabled ? 'Sites unblock when you are not focusing.' : 'Blocking is off.'
  $('main').textContent = s?.status === 'running' ? 'Pause' : s?.status === 'paused' ? 'Resume' : s?.phase === 'rest' ? 'Start Break' : 'Start Focus'
  $('main').disabled = $('stop').disabled = !s
  $('stop').hidden = !(s?.status === 'running' || s?.status === 'paused')
  $('enabled').checked = o.enabled
  $('puzzle').checked = o.puzzle
  $('sites').replaceChildren(...o.sites.map(d => {
    const li = document.createElement('li'), x = document.createElement('button')
    li.textContent = d
    x.textContent = '×'
    x.setAttribute('aria-label', `Remove ${d}`)
    x.onclick = () => ext.storage.sync.set({ sites: o.sites.filter(v => v !== d) })
    li.append(x)
    return li
  }))
  tick()
}
function tick() { if (l.wire?.s) $('clock').textContent = fmt(left(l.wire.s)) }

$('code').oninput = async e => {
  const v = e.target.value = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6)
  $('err').textContent = ''
  if (v.length < 6) return
  e.target.disabled = true
  const r = await send({ pair: v })
  e.target.disabled = false
  if (r?.error) { $('err').textContent = r.error === 'code' ? "That code didn't work. Check it, or make a new one." : "Can't reach sync right now. Check your connection."; e.target.focus() }
  else e.target.value = ''
}
$('main').onclick = () => send({ control: l.wire.s.status === 'running' ? 'pause' : l.wire.s.status === 'paused' ? 'resume' : 'start' })
$('stop').onclick = () => send({ control: 'stop' })
$('leave').onclick = () => send({ leave: 1 })
$('enabled').onchange = e => ext.storage.sync.set({ enabled: e.target.checked })
$('puzzle').onchange = e => ext.storage.sync.set({ puzzle: e.target.checked })
$('add').onsubmit = e => {
  e.preventDefault()
  let d = $('site').value.trim().toLowerCase()
  try { d = new URL(d.includes('://') ? d : 'https://' + d).hostname.replace(/^www\./, '') } catch { d = '' }
  if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(d)) return $('siteErr').textContent = 'Enter a site like news.com.'
  $('siteErr').textContent = ''
  $('site').value = ''
  if (!o.sites.includes(d)) ext.storage.sync.set({ sites: [...o.sites, d] })
}
ext.storage.onChanged.addListener(render)
setInterval(tick, 1000)
render()
