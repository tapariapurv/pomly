// Shared by the worker, the popup and the blocked page.
export const REF = 978307200 // Swift encodes Dates as seconds since 2001; this is that moment in Unix seconds
export const DEFAULT_SITES = ['youtube.com', 'x.com', 'twitter.com', 'reddit.com', 'instagram.com', 'facebook.com', 'tiktok.com', 'netflix.com', 'twitch.tv']

export const settings = async () => ({ sites: DEFAULT_SITES, enabled: true, puzzle: true, ...await chrome.storage.sync.get(['sites', 'enabled', 'puzzle']) })
export const endMs = s => s?.endDate == null ? 0 : (s.endDate + REF) * 1000
export const left = s => !s ? 0 : s.status === 'running' ? Math.max(0, (endMs(s) - Date.now()) / 1000) : s.status === 'paused' ? s.remaining : s.status === 'idle' ? s.planned : 0

/// Sites stay blocked for the whole focus session, paused included; breaks are free.
export const blocking = (local, { enabled }) => {
  const s = local.wire?.s
  return !!(local.space && enabled && s?.phase === 'focus' && (s.status === 'paused' || (s.status === 'running' && endMs(s) > Date.now())))
}

export const ALLOW_MIN = 5 // "Open Anyway" unblocks a site for this long
export const site = (host, sites) => sites.find(d => host === d || host.endsWith('.' + d))
export const fmt = sec => { sec = Math.ceil(sec); return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}` }

/// One redirect rule per site, subdomains included. The whole URL rides along so the tab can return to it.
export const pattern = d => `^https?://([^/?#]*\\.)?${d.replaceAll('.', '\\.')}([/?#:].*)?$`
