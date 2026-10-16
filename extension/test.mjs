// node extension/test.mjs — checks the block rule pattern and the blocking decision.
import assert from 'node:assert'
import { pattern, blocking, REF } from './shared.js'
const re = new RegExp(pattern('youtube.com'))
for (const u of ['https://youtube.com', 'https://www.youtube.com/watch?v=1', 'http://m.youtube.com:443/x', 'https://youtube.com?x', 'https://youtube.com#a']) assert(re.test(u), u)
for (const u of ['https://notyoutube.com', 'https://youtube.com.evil.io/', 'https://google.com/?q=youtube.com', 'https://youtubexcom']) assert(!re.test(u), u)
const now = Date.now() / 1000 - REF, on = { enabled: true }
const st = (phase, status, endDate) => ({ space: 'S', wire: { s: { phase, status, endDate, remaining: 60, planned: 60 } } })
assert(blocking(st('focus', 'running', now + 60), on))
assert(blocking(st('focus', 'paused'), on))
assert(!blocking(st('focus', 'running', now - 1), on))
assert(!blocking(st('rest', 'running', now + 60), on))
assert(!blocking(st('focus', 'idle'), on))
assert(!blocking(st('focus', 'running', now + 60), { enabled: false }))
assert(!blocking({ ...st('focus', 'paused'), space: undefined }, on))
console.log('ok')
