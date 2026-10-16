import { ALLOW_MIN, settings, site, left, blocking, fmt } from './shared.js'
const $ = id => document.getElementById(id)
const url = location.hash.slice(1)
let host = ''
try { host = new URL(url).hostname.replace(/^www\./, '') } catch {}
let s

async function check() {
  const l = await chrome.storage.local.get(['wire', 'space'])
  if (!blocking(l, await settings())) return url ? location.replace(url) : history.back() // session over: back to where you were
  s = l.wire.s
  tick()
}
function tick() {
  if (!s) return
  const t = left(s)
  $('clock').textContent = fmt(t)
  $('fill').style.strokeDashoffset = s.planned ? 1 - t / s.planned : 0
  $('msg').textContent = `${host || 'This site'} is blocked ${s.status === 'paused' ? 'while your focus session is paused' : `for ${fmt(t)} more`}. It opens again when the session ends.`
  if (s.status === 'running' && t <= 0) check()
}
// Open Anyway: optional friction first, then the site is unblocked for a few minutes.
let answer
const ask = () => { const a = 12 + Math.floor(Math.random() * 38), b = 6 + Math.floor(Math.random() * 4); answer = a * b; $('q').textContent = `${a} × ${b} =`; $('ans').value = '' }
async function open() {
  const d = site(host, (await settings()).sites)
  if (d) await chrome.runtime.sendMessage({ allow: d })
  location.replace(url)
}
$('open').onclick = async () => {
  if (!(await settings()).puzzle) return open()
  ask()
  $('hint').textContent = `Solve it to open ${host || 'this site'} for ${ALLOW_MIN} minutes.`
  $('quiz').hidden = false
  $('ans').focus()
}
$('quiz').onsubmit = e => {
  e.preventDefault()
  if (+$('ans').value === answer) return open()
  $('hint').textContent = 'Not quite. Try this one.'
  ask()
}
$('open').hidden = !url
$('back').onclick = () => history.length > 1 ? history.back() : chrome.tabs.getCurrent(t => chrome.tabs.remove(t.id))
chrome.storage.onChanged.addListener(check)
setInterval(tick, 1000)
check()
