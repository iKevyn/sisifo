// Sísifo · conversas: servidor local que lê SÓ conversas privadas
// do banco da ponte do WhatsApp e manda mensagens pela mesma ponte.
// Sem IA, sem grupos, sem nuvem. Os dados ficam neste Mac.
import http from 'node:http'
import { DatabaseSync } from 'node:sqlite'
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync, readdirSync, rmSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import os from 'node:os'
import path from 'node:path'

import { HOME, CHAT_PORT, DB_PATH, TOKEN_PATH, BRIDGE, WA_DATA, equipeNumeros } from '../server/config.mjs'
const PORT = CHAT_PORT
const DIR = path.join(HOME, 'conversas')
const AVATARS = path.join(DIR, 'avatars')
const STATE_FILE = path.join(DIR, 'state.json')
while (!existsSync(DB_PATH)) await new Promise((r) => setTimeout(r, 2000))
const STICKER_DIR = path.join(DIR, 'stickers')                    // figurinhas que você adicionar
const WA_STICKERS = path.join(os.homedir(), 'Library/Group Containers/group.net.whatsapp.WhatsApp.shared/stickers/no-sticker-pack')
const AUDIO_DIR = path.join(DIR, 'audio')
const TRANSCRIPTS_FILE = path.join(DIR, 'transcripts.json')
mkdirSync(AVATARS, { recursive: true })
mkdirSync(STICKER_DIR, { recursive: true })
mkdirSync(AUDIO_DIR, { recursive: true })

let transcripts = {}
try { transcripts = JSON.parse(readFileSync(TRANSCRIPTS_FILE, 'utf8')) } catch {}
let transT = null
const saveTranscripts = () => {
  clearTimeout(transT)
  transT = setTimeout(() => {
    try { writeFileSync(TRANSCRIPTS_FILE, JSON.stringify(transcripts), { mode: 0o600 }) } catch {}
  }, 300)
}
const tkey = (jid, id) => `${jid}|${id}`
const run = (cmd, args, timeout = 600000) => new Promise((res, rej) =>
  execFile(cmd, args, { maxBuffer: 20e6, timeout }, (e, out, err) => e ? rej(new Error(err || e.message)) : res(out)))
const WHISPER = ['/opt/homebrew/bin/whisper-cli', 'whisper-cli'].find((p) => p.includes('/') ? existsSync(p) : true)
const FFMPEG = existsSync('/opt/homebrew/bin/ffmpeg') ? '/opt/homebrew/bin/ffmpeg' : 'ffmpeg'
const MODEL = path.join(WA_DATA, 'models/ggml-small.bin')

const log = (...a) => console.log(new Date().toISOString(), ...a)
const now = () => Math.floor(Date.now() / 1000)
const db = new DatabaseSync(DB_PATH, { readOnly: true })
db.exec('PRAGMA busy_timeout = 5000')
const me = db.prepare("SELECT v FROM kv WHERE k = 'me'").get()?.v || ''

// só o que eu marquei como lido dentro do app (não mexo no banco da ponte)
let st = { read: {} }
try { st = { ...st, ...JSON.parse(readFileSync(STATE_FILE, 'utf8')) } } catch {}
let saveT = null
const save = () => {
  clearTimeout(saveT)
  saveT = setTimeout(() => {
    try { writeFileSync(STATE_FILE, JSON.stringify(st), { mode: 0o600 }) } catch {}
  }, 200)
}

const REAL = `('conversation','extendedTextMessage','imageMessage','audioMessage','videoMessage','documentMessage',
  'documentWithCaptionMessage','albumMessage','contactMessage','locationMessage','pollCreationMessage','pollCreationMessageV3',
  'stickerMessage')`
const MEDIA = {
  imageMessage: '📷 Foto', audioMessage: '🎙 Áudio', videoMessage: '🎬 Vídeo',
  documentMessage: '📄 Documento', documentWithCaptionMessage: '📄 Documento',
  albumMessage: '🖼 Fotos', contactMessage: '👤 Contato', locationMessage: '📍 Localização',
  stickerMessage: '🎭 Figurinha',
}
const PRIVATE = `c.is_group = 0 AND c.jid NOT LIKE '%@g.us' AND c.jid NOT LIKE '%@broadcast'
  AND c.jid NOT LIKE '%@newsletter' AND c.jid <> 'status@broadcast'`

const isPrivate = (jid) => !!jid && !String(jid).includes('@g.us') && !String(jid).includes('@broadcast') && !String(jid).includes('@newsletter')
const isGroup = (jid) => !!jid && String(jid).endsWith('@g.us')
// conversa que o Zap pode abrir/responder: privada ou grupo (nunca status/canal)
const isChat = (jid) => isPrivate(jid) || isGroup(jid)

// Trabalho = grupos onde eu e gente da minha equipe (configurada na primeira abertura) conversamos
let WAVE = []
let workCache = { at: 0, set: new Set() }
function workGroups () {
  if (Date.now() - workCache.at < 60000) return workCache.set
  WAVE = equipeNumeros().map((n) => n + '@s.whatsapp.net')
  if (!WAVE.length) { workCache = { at: Date.now(), set: new Set() }; return workCache.set }
  const minimo = Math.min(2, WAVE.length)
  try {
    const ids = new Set(WAVE)
    for (const r of db.prepare(`SELECT lid FROM lid_map WHERE pn IN (${WAVE.map(() => '?').join(',')})`).all(...WAVE)) ids.add(r.lid)
    const lidPn = new Map(db.prepare(`SELECT lid, pn FROM lid_map WHERE pn IN (${WAVE.map(() => '?').join(',')})`).all(...WAVE).map((r) => [r.lid, r.pn]))
    const rows = db.prepare(`SELECT DISTINCT chat_jid, sender_jid FROM messages
      WHERE chat_jid LIKE '%@g.us' AND sender_jid IN (${[...ids].map(() => '?').join(',')})`).all(...ids)
    const per = new Map()
    for (const r of rows) {
      const who = lidPn.get(r.sender_jid) || r.sender_jid
      if (!per.has(r.chat_jid)) per.set(r.chat_jid, new Set())
      per.get(r.chat_jid).add(who)
    }
    workCache = { at: Date.now(), set: new Set([...per].filter(([, w]) => w.size >= minimo).map(([j]) => j)) }
  } catch { workCache.at = Date.now() }
  return workCache.set
}
// nome de quem mandou (grupos): contato salvo, senão o push_name
function senderName (jid, push) {
  if (!jid) return push || ''
  const pn = db.prepare('SELECT pn FROM lid_map WHERE lid = ?').get(jid)?.pn
  const c = db.prepare("SELECT COALESCE(NULLIF(name,''), NULLIF(notify,'')) n FROM contacts WHERE jid IN (?, ?)").get(jid, pn || jid)?.n
  return (c || push || (pn || jid).split('@')[0]).split(' ').slice(0, 2).join(' ')
}

const countAfter = (jid, ts) => Number(db.prepare(
  'SELECT COUNT(*) n FROM messages WHERE chat_jid = ? AND from_me = 0 AND ts > ?'
).get(jid, ts)?.n || 0)
const lastDbTs = () => Number(db.prepare('SELECT MAX(ts) t FROM messages').get()?.t || 0)

function incomingSince (ts) {
  const since = Number(ts || 0)
  if (!since) return []
  const rows = db.prepare(`SELECT m.id, m.chat_jid jid, m.ts, m.type, m.text, m.transcript,
      COALESCE(NULLIF(ct.name,''), NULLIF(ct.notify,''), NULLIF(c.name,''), m.chat_jid) name
    FROM messages m
    JOIN chats c ON c.jid = m.chat_jid
    LEFT JOIN contacts ct ON ct.jid = m.chat_jid
    WHERE m.from_me = 0 AND m.ts > ? AND m.type IN ${REAL} AND ${PRIVATE}
    ORDER BY m.ts DESC LIMIT 20`).all(since)
  return rows.map((r) => {
    const t = (r.text || '').replace(/\s+/g, ' ').trim()
    return {
      id: r.id, jid: r.jid, ts: Number(r.ts || 0), name: r.name,
      text: r.transcript || (t && !/^\[.*\]$/.test(t) ? t : MEDIA[r.type] || 'Nova mensagem'),
    }
  })
}

function preview (m, groupJid) {
  if (!m) return ''
  const t = (m.text || '').replace(/\s+/g, ' ').trim()
  const prefix = m.from_me ? 'Tu: ' : (groupJid && m.sender_jid ? senderName(m.sender_jid, m.push_name) + ': ' : '')
  if (m.type === 'audioMessage') return prefix + (m.transcript ? `🎙 ${m.transcript.slice(0, 70)}` : '🎙 Áudio')
  if (MEDIA[m.type]) return prefix + MEDIA[m.type] + (t ? ` ${t.slice(0, 70)}` : '')
  return prefix + t.slice(0, 120)
}

// "ok, li" dado nas não lidas do Zap (servidor de demandas) também conta como lido aqui
const PEND_STATE = path.join(HOME, 'demandas/demandas.json')
let pendCache = { mtime: 0, read: {} }
function pendenteRead () {
  try {
    const m = statSync(PEND_STATE).mtimeMs
    if (m !== pendCache.mtime) pendCache = { mtime: m, read: JSON.parse(readFileSync(PEND_STATE, "utf8")).readLocal || {} }
  } catch {}
  return pendCache.read
}

function chats () {
  const pend = pendenteRead()
  const work = [...workGroups()]
  const rows = db.prepare(`
    SELECT c.jid,
      COALESCE(NULLIF(ct.name,''), NULLIF(ct.notify,''), NULLIF(c.name,''), c.jid) AS name,
      c.last_ts, COALESCE(r.read_ts,0) AS read_ts, COALESCE(r.marked_unread,0) AS marked_unread
    FROM chats c
    LEFT JOIN contacts ct ON ct.jid = c.jid
    LEFT JOIN reads r ON r.jid = c.jid
    WHERE (${PRIVATE}) OR c.jid IN (${work.map(() => '?').join(',') || "''"})
    ORDER BY c.last_ts DESC LIMIT 160`).all(...work)
  return rows.map((r) => {
    const last = db.prepare(`SELECT from_me, type, text, transcript, sender_jid, push_name FROM messages
      WHERE chat_jid = ? AND type IN ${REAL} ORDER BY ts DESC LIMIT 1`).get(r.jid)
    const override = Math.max(Number(st.read[r.jid] || 0), Number(pend[r.jid] || 0))
    const ref = Math.max(Number(r.read_ts || 0), override)
    let unread = 0
    if (override < Number(r.last_ts || 0)) {
      // respondi depois = já li (igual às não lidas do Zap)
      const lastMine = Number(db.prepare('SELECT MAX(ts) t FROM messages WHERE chat_jid = ? AND from_me = 1').get(r.jid)?.t || 0)
      if (r.marked_unread) {
        unread = Math.max(1, countAfter(r.jid, Math.max(ref, lastMine)))
      } else {
        unread = countAfter(r.jid, Math.max(ref, lastMine))
      }
    }
    const group = isGroup(r.jid)
    return { jid: r.jid, name: r.name, last: preview(last, group ? r.jid : null), lastTs: Number(r.last_ts || 0), unread, group, work: group }
  })
}

function messages (jid) {
  if (!isChat(jid)) return []
  const group = isGroup(jid)
  const rows = db.prepare(`SELECT id, from_me, ts, type, text, transcript, media_path, sender_jid, push_name
    FROM messages WHERE chat_jid = ? AND type IN ${REAL} ORDER BY ts DESC LIMIT 80`).all(jid).reverse()
  return rows.map((m) => {
    const raw = (m.text || '').replace(/\s+/g, ' ').trim()
    const caption = raw && !/^\[.*\]$/.test(raw) ? raw : ''
    let text = raw
    if (m.type === 'stickerMessage') text = ''
    else if (m.transcript) text = m.transcript
    else if (m.type === 'audioMessage') text = ''
    else if (MEDIA[m.type]) text = caption ? `${MEDIA[m.type]} ${caption}` : MEDIA[m.type]
    return {
      id: m.id, jid, me: !!m.from_me, ts: Number(m.ts || 0), type: m.type,
      who: group && !m.from_me ? senderName(m.sender_jid, m.push_name) : null,
      text, caption, transcript: cachedTranscript(jid, m.id) || null,
      media: (!!m.media_path || m.type === 'stickerMessage') &&
        ['imageMessage', 'videoMessage', 'albumMessage', 'stickerMessage'].includes(m.type),
    }
  })
}

// monta a citação a partir do banco local — o app só manda o id da mensagem
function quoteFor (jid, id) {
  if (!isChat(jid) || !id) return null
  const m = db.prepare('SELECT id, from_me, type, text, transcript FROM messages WHERE chat_jid = ? AND id = ?').get(jid, id)
  if (!m) return null
  const raw = (m.text || '').replace(/\s+/g, ' ').trim()
  const text = m.transcript || (raw && !/^\[.*\]$/.test(raw) ? raw : MEDIA[m.type] || 'Mensagem')
  return { jid, id: m.id, me: !!m.from_me, text: String(text).slice(0, 300), type: m.type }
}

async function bridgeOk () {
  try {
    const token = readFileSync(TOKEN_PATH, 'utf8').trim()
    const r = await fetch(`${BRIDGE}/status`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(1500) })
    return (await r.json()).connected === true
  } catch { return false }
}

async function sendToBridge (jid, text, quoted) {
  const token = readFileSync(TOKEN_PATH, 'utf8').trim()
  const r = await fetch(`${BRIDGE}/send`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ jid, text, quoted }),
    signal: AbortSignal.timeout(20000),
  })
  const j = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(j.error || `ponte respondeu ${r.status}`)
  return j
}

// presença (digitando/gravando) é consulta leve: 1 chamada por poll do app, com mini-cache
let presenceCache = { jid: '', at: 0, data: { typing: false, recording: false } }
async function presenceFor (jid) {
  if (!isPrivate(jid)) return { typing: false, recording: false }
  if (presenceCache.jid === jid && Date.now() - presenceCache.at < 700) return presenceCache.data
  const token = readFileSync(TOKEN_PATH, 'utf8').trim()
  try {
    const r = await fetch(`${BRIDGE}/presence?jid=${encodeURIComponent(jid)}`, {
      headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(1500),
    })
    const j = await r.json().catch(() => ({}))
    const data = { typing: !!j.typing, recording: !!j.recording }
    presenceCache = { jid, at: Date.now(), data }
    return data
  } catch { return presenceCache.jid === jid ? presenceCache.data : { typing: false, recording: false } }
}

// fotos: cache em disco por 2 dias, igual o outro app
const avatarPending = new Map()
async function avatarFile (jid) {
  if (!isChat(jid)) return null
  const f = path.join(AVATARS, createHash('sha1').update(jid).digest('hex') + '.jpg')
  const miss = f + '.none'
  const fresh = (p) => existsSync(p) && Date.now() - statSync(p).mtimeMs < 2 * 86400e3
  if (fresh(f)) return f
  if (fresh(miss)) return null
  if (avatarPending.has(jid)) return avatarPending.get(jid)
  const job = (async () => {
    try {
      const token = readFileSync(TOKEN_PATH, 'utf8').trim()
      const r = await fetch(`${BRIDGE}/avatar?jid=${encodeURIComponent(jid)}`, {
        headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(8000),
      })
      if (r.status === 503) return existsSync(f) ? f : null
      if (!r.ok) { writeFileSync(miss, ''); return null }
      const { url } = await r.json()
      const img = await fetch(url, { signal: AbortSignal.timeout(10000) })
      if (!img.ok) { writeFileSync(miss, ''); return null }
      writeFileSync(f, Buffer.from(await img.arrayBuffer()))
      return f
    } catch { return existsSync(f) ? f : null } finally { avatarPending.delete(jid) }
  })()
  avatarPending.set(jid, job)
  return job
}

async function thumbFile (jid, id) {
  if (!isChat(jid) || !id) return null
  const row = db.prepare('SELECT media_path FROM messages WHERE chat_jid = ? AND id = ?').get(jid, id)
  if (row?.media_path && existsSync(row.media_path)) return row.media_path
  try {
    const token = readFileSync(TOKEN_PATH, 'utf8').trim()
    const r = await fetch(`${BRIDGE}/media`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ chat: jid, id }),
      signal: AbortSignal.timeout(20000),
    })
    const j = await r.json().catch(() => ({}))
    return j.path && existsSync(j.path) ? j.path : null
  } catch { return null }
}

// áudio: converte pra m4a (o AVAudioPlayer do macOS toca) e guarda em cache
const audioJobs = new Map()
async function audioFile (jid, id) {
  if (!isChat(jid) || !id) return null
  const k = tkey(jid, id)
  const f = path.join(AUDIO_DIR, createHash('sha1').update(k).digest('hex') + '.m4a')
  if (existsSync(f) && statSync(f).size > 0) return f
  if (audioJobs.has(k)) return audioJobs.get(k)
  const job = (async () => {
    const src = await thumbFile(jid, id)
    if (!src) return null
    try {
      await run(FFMPEG, ['-y', '-loglevel', 'error', '-i', src, '-vn', '-ac', '1', '-b:a', '64k', f])
      return f
    } catch { return null }
  })()
  audioJobs.set(k, job)
  try { return await job } finally { audioJobs.delete(k) }
}

// transcrição local com Whisper (só quando o usuário pede), cacheada em disco
function cachedTranscript (jid, id) {
  if (!jid || !id) return ''
  return transcripts[tkey(jid, id)] ||
    db.prepare('SELECT transcript FROM messages WHERE chat_jid = ? AND id = ?').get(jid, id)?.transcript || ''
}
const transJobs = new Map()
async function transcribe (jid, id) {
  const hit = cachedTranscript(jid, id)
  if (hit) return hit
  if (!isChat(jid) || !id) throw new Error('conversa inválida')
  const k = tkey(jid, id)
  if (transJobs.has(k)) return transJobs.get(k)
  const job = (async () => {
    const src = await thumbFile(jid, id)
    if (!src) throw new Error('áudio não disponível')
    if (!existsSync(MODEL) || !WHISPER) throw new Error('Whisper não está instalado')
    const wav = path.join(os.tmpdir(), `zp-${process.pid}-${Date.now()}.wav`)
    try {
      await run(FFMPEG, ['-y', '-loglevel', 'error', '-i', src, '-ar', '16000', '-ac', '1', wav])
      const out = await run(WHISPER, ['-m', MODEL, '-l', 'pt', '-nt', '-np', '-f', wav])
      const text = out.replace(/\s+/g, ' ').trim() || '(áudio sem fala)'
      transcripts[k] = text
      saveTranscripts()
      return text
    } finally { try { rmSync(wav, { force: true }) } catch {} }
  })()
  transJobs.set(k, job)
  try { return await job } finally { transJobs.delete(k) }
}

// figurinhas WebP: as suas (pasta do app) + as que já chegaram no WhatsApp Desktop
const stickerDirs = [STICKER_DIR, WA_STICKERS].filter(existsSync)
function stickerList () {
  const out = []
  for (const dir of stickerDirs) {
    let files = []
    try { files = readdirSync(dir) } catch {}
    for (const f of files.sort()) {
      if (!/\.webp$/i.test(f)) continue
      const full = path.join(dir, f)
      if (!existsSync(full)) continue
      out.push({
        id: Buffer.from(full).toString('base64url'),
        name: f.replace(/\.webp$/i, '').replace(/[-_]/g, ' ').slice(0, 30),
        mine: dir === STICKER_DIR,
      })
    }
  }
  return out
}
function stickerPath (id) {
  try {
    const full = path.resolve(Buffer.from(String(id || ''), 'base64url').toString('utf8'))
    if (!stickerDirs.some((d) => full.startsWith(path.resolve(d) + path.sep))) return null
    return /\.webp$/i.test(full) && existsSync(full) ? full : null
  } catch { return null }
}

// respostas rápidas: frases que eu mais escrevo (neste chat + no geral), sem IA e sem nuvem
const norm = (s) => s.toLowerCase().replace(/\s+/g, ' ').replace(/[.!?,;:]+$/g, '').trim()
function frequent (jid) {
  const rows = db.prepare(`SELECT text, ts AS last FROM messages
    WHERE from_me = 1 AND type IN ${REAL} AND text IS NOT NULL
      AND LENGTH(TRIM(text)) BETWEEN 2 AND 70
      ${jid && isPrivate(jid) ? 'AND chat_jid = ?' : ''}
    ORDER BY ts DESC LIMIT 4000`).all(...(jid && isPrivate(jid) ? [jid] : []))
  const hits = new Map()
  for (const r of rows) {
    const text = String(r.text).replace(/\s+/g, ' ').trim()
    if (!text || text.startsWith('[') || /^https?:\/\//i.test(text)) continue
    const k = norm(text)
    if (!k || k.length < 2) continue
    const h = hits.get(k) || { n: 0, last: 0, text }
    h.n++; h.last = Math.max(h.last, Number(r.last || 0))
    hits.set(k, h)
  }
  return [...hits.values()].sort((a, b) => b.n - a.n || b.last - a.last).slice(0, 12)
}
function suggestions (jid) {
  const here = frequent(jid)
  const everywhere = frequent(null)
  const out = []
  const seen = new Set()
  for (const [list, weight] of [[here, 3], [everywhere, 1]]) {
    for (const h of list) {
      const k = norm(h.text)
      if (seen.has(k)) continue
      seen.add(k)
      out.push({ text: h.text, score: h.n * weight, n: h.n, last: h.last })
    }
  }
  out.sort((a, b) => b.score - a.score || b.last - a.last)
  const items = out.slice(0, 7).map((x) => x.text)
  return items.length ? items : ['Obrigado!', 'Pode ser', 'Beijo']
}

// envio de arquivo arrastado: imagem vai como foto, áudio vira mensagem de voz (ogg/opus)
const OUT_DIR = path.join(DIR, 'enviados')
mkdirSync(OUT_DIR, { recursive: true })
const IMG_EXT = ['png', 'jpg', 'jpeg', 'webp', 'gif']
const AUD_EXT = ['ogg', 'opus', 'mp3', 'm4a', 'aac', 'wav', 'aiff', 'aif', 'caf', 'flac']
async function prepareFile (file) {
  if (!file || !existsSync(file)) throw new Error('arquivo não encontrado')
  const size = statSync(file).size
  if (size > 60e6) throw new Error('arquivo grande demais (máx 60 MB)')
  const ext = path.extname(file).slice(1).toLowerCase()
  const tag = createHash('sha1').update(file + size).digest('hex').slice(0, 12)
  if (['heic', 'heif', 'tiff', 'tif', 'bmp'].includes(ext)) {
    const out = path.join(OUT_DIR, tag + '.jpg')
    if (!existsSync(out)) await run('/usr/bin/sips', ['-s', 'format', 'jpeg', file, '--out', out], 60000)
    return { file: out, kind: 'imagem' }
  }
  if (IMG_EXT.includes(ext)) return { file, kind: 'imagem' }
  if (['mp4', 'mov'].includes(ext)) return { file, kind: 'vídeo' }
  if (AUD_EXT.includes(ext)) {
    if (ext === 'ogg' || ext === 'opus') return { file, kind: 'áudio' }
    const out = path.join(OUT_DIR, tag + '.ogg')
    if (!existsSync(out)) await run(FFMPEG, ['-y', '-i', file, '-vn', '-ac', '1', '-ar', '48000', '-c:a', 'libopus', '-b:a', '32k', out], 120000)
    return { file: out, kind: 'áudio' }
  }
  return { file, kind: 'arquivo' }
}
async function bridgePost (route, payload, timeout = 60000) {
  const token = readFileSync(TOKEN_PATH, 'utf8').trim()
  const r = await fetch(`${BRIDGE}${route}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(timeout),
  })
  const j = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(j.error || `ponte respondeu ${r.status}`)
  return j
}

const body = (req) => new Promise((res) => {
  let s = ''
  req.on('data', (c) => { s += c; if (s.length > 1e5) req.destroy() })
  req.on('end', () => { try { res(JSON.parse(s || '{}')) } catch { res({}) } })
})
const send = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)) }

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x')
    if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true })
    if (req.method === 'GET' && url.pathname === '/state') {
      const jid = url.searchParams.get('chat') || ''
      const since = url.searchParams.get('since') || ''
      return send(res, 200, {
        connected: await bridgeOk(), chats: chats(), messages: messages(jid), me,
        dbTs: lastDbTs(), incoming: incomingSince(since),
      })
    }
    if (req.method === 'GET' && url.pathname === '/presence') {
      const p = await presenceFor(url.searchParams.get('chat') || '')
      return send(res, 200, p)
    }
    if (req.method === 'GET' && url.pathname === '/avatar') {
      const f = await avatarFile(url.searchParams.get('jid') || '')
      if (!f) { res.writeHead(404); return res.end() }
      res.writeHead(200, { 'content-type': 'image/jpeg', 'cache-control': 'max-age=3600' })
      return res.end(readFileSync(f))
    }
    if (req.method === 'GET' && url.pathname === '/thumb') {
      const f = await thumbFile(url.searchParams.get('jid') || '', url.searchParams.get('id') || '')
      if (!f) { res.writeHead(404); return res.end() }
      const ext = path.extname(f).slice(1).toLowerCase()
      const type = ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : 'image/jpeg'
      res.writeHead(200, { 'content-type': type, 'cache-control': 'max-age=86400' })
      return res.end(readFileSync(f))
    }
    if (req.method === 'GET' && url.pathname === '/audio') {
      const f = await audioFile(url.searchParams.get('jid') || '', url.searchParams.get('id') || '')
      if (!f) { res.writeHead(404); return res.end() }
      res.writeHead(200, { 'content-type': 'audio/mp4', 'cache-control': 'max-age=86400' })
      return res.end(readFileSync(f))
    }
    if (req.method === 'GET' && url.pathname === '/suggestions') {
      return send(res, 200, { items: suggestions(url.searchParams.get('chat') || '') })
    }
    if (req.method === 'GET' && url.pathname === '/stickers') return send(res, 200, { items: stickerList() })
    if (req.method === 'GET' && url.pathname === '/sticker-img') {
      const f = stickerPath(url.searchParams.get('id') || '')
      if (!f) { res.writeHead(404); return res.end() }
      res.writeHead(200, { 'content-type': 'image/webp', 'cache-control': 'max-age=3600' })
      return res.end(readFileSync(f))
    }

    const b = req.method === 'POST' ? await body(req) : {}
    if (req.method === 'POST' && url.pathname === '/transcribe') {
      try {
        const text = await transcribe(b.jid, b.id)
        return send(res, 200, { ok: true, text })
      } catch (e) { return send(res, 500, { error: e.message }) }
    }
    if (req.method === 'POST' && url.pathname === '/sticker') {
      const f = stickerPath(b.id)
      if (!isChat(b.jid)) return send(res, 400, { error: 'conversa inválida' })
      if (!f) return send(res, 400, { error: 'figurinha não encontrada' })
      try {
        const token = readFileSync(TOKEN_PATH, 'utf8').trim()
        const r = await fetch(`${BRIDGE}/sticker`, {
          method: 'POST',
          headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
          body: JSON.stringify({ jid: b.jid, file: f }),
          signal: AbortSignal.timeout(20000),
        })
        const j = await r.json().catch(() => ({}))
        if (!r.ok) return send(res, 502, { error: j.error || 'ponte recusou a figurinha' })
        st.read[b.jid] = Math.max(Number(st.read[b.jid] || 0), now()); save()
        return send(res, 200, { ok: true, id: j.id || null })
      } catch (e) { return send(res, 502, { error: e.message }) }
    }
    if (req.method === 'POST' && url.pathname === '/read') {
      if (isChat(b.jid)) { st.read[b.jid] = Math.max(Number(st.read[b.jid] || 0), now()); save() }
      return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/send-file') {
      if (!isChat(b.jid)) return send(res, 400, { error: 'conversa inválida' })
      try {
        const f = await prepareFile(String(b.path || ''))
        const caption = String(b.text || '').trim() || undefined
        const r = await bridgePost('/send', { jid: b.jid, file: f.file, text: f.kind === 'áudio' ? undefined : caption })
        st.read[b.jid] = Math.max(Number(st.read[b.jid] || 0), now()); save()
        return send(res, 200, { ok: true, id: r.id || null, text: f.kind })
      } catch (e) { return send(res, 502, { error: e.message }) }
    }
    if (req.method === 'POST' && url.pathname === '/sync') {
      // sincronizar agora: pede pra ponte buscar o que faltou na conversa aberta (espera até 10s)
      const ok = await bridgeOk()
      if (!ok) return send(res, 503, { error: 'ponte do WhatsApp offline' })
      if (isChat(b.jid)) {
        try { await bridgePost('/history', { chat: b.jid }, 12000) } catch (e) { log('sync', e.message) }
      }
      return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/send') {
      const text = String(b.text || '').trim()
      if (!isChat(b.jid)) return send(res, 400, { error: 'conversa inválida' })
      if (!text) return send(res, 400, { error: 'mensagem vazia' })
      const r = await sendToBridge(b.jid, text, quoteFor(b.jid, b.quote))
      st.read[b.jid] = Math.max(Number(st.read[b.jid] || 0), now()); save()
      return send(res, 200, { ok: true, id: r.id || null })
    }
    send(res, 404, { error: 'rota' })
  } catch (e) {
    log('erro', e.message)
    send(res, 500, { error: e.message })
  }
}).on('error', (e) => { log('servidor não subiu', e.message); process.exit(1) })
  .listen(PORT, '127.0.0.1', () => log(`Zap Privado em http://127.0.0.1:${PORT}`))

process.on('uncaughtException', (e) => { log('uncaught', e?.message); process.exit(1) })
