// Ponte: conecta no WhatsApp como "aparelho conectado" (igual ao ZapFast/WhatsApp Web),
// guarda conversas no SQLite local e expõe um endpoint de envio só em 127.0.0.1 com token.
// Não marca mensagens como lidas, não fica "online" e não envia nada sozinha.
import makeWASocket, {
  useMultiFileAuthState, DisconnectReason, Browsers, fetchLatestBaileysVersion,
  normalizeMessageContent, getContentType, jidNormalizedUser, isJidGroup,
  downloadMediaMessage, BufferJSON
} from 'baileys'
import QRCode from 'qrcode'
import pino from 'pino'
import http from 'node:http'
import { randomBytes } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync, rmSync, readdirSync } from 'node:fs'
import { execFile } from 'node:child_process'
import path from 'node:path'
import { openDb, DATA, MEDIA, canonJid } from './db.js'

const PORT = Number(process.env.WA_BRIDGE_PORT || 47821)
const TOKEN_FILE = path.join(DATA, 'token')
if (!existsSync(TOKEN_FILE)) writeFileSync(TOKEN_FILE, randomBytes(24).toString('hex'), { mode: 0o600 })
const TOKEN = readFileSync(TOKEN_FILE, 'utf8').trim()

const db = openDb()
const log = pino({ level: process.env.WA_LOG || 'warn' })
const setKv = db.prepare('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v')

const num = (x) => (x && typeof x === 'object' && typeof x.toNumber === 'function') ? x.toNumber() : Number(x || 0)

const upChat = db.prepare(`INSERT INTO chats (jid, name, is_group, last_ts) VALUES (?, ?, ?, ?)
  ON CONFLICT(jid) DO UPDATE SET name = COALESCE(excluded.name, chats.name),
  last_ts = MAX(chats.last_ts, excluded.last_ts)`)
const upArchived = db.prepare(`INSERT INTO chats (jid, archived) VALUES (?, ?)
  ON CONFLICT(jid) DO UPDATE SET archived = excluded.archived`)
const upContact = db.prepare(`INSERT INTO contacts (jid, name, notify) VALUES (?, ?, ?)
  ON CONFLICT(jid) DO UPDATE SET name = COALESCE(excluded.name, contacts.name),
  notify = COALESCE(excluded.notify, contacts.notify)`)
const upMsg = db.prepare(`INSERT INTO messages (chat_jid, id, sender_jid, from_me, ts, type, text, push_name, raw)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(chat_jid, id) DO UPDATE SET text = COALESCE(excluded.text, messages.text),
  raw = COALESCE(excluded.raw, messages.raw)`)

// ---- LID ↔ telefone: o WhatsApp manda a mesma pessoa às vezes como "123@lid", às vezes pelo número.
// Guardamos o mapeamento e gravamos tudo no número, pra cada pessoa ser UMA conversa.
const upLid = db.prepare('INSERT INTO lid_map (lid, pn) VALUES (?, ?) ON CONFLICT(lid) DO UPDATE SET pn = excluded.pn')
const userOf = (j) => String(j).split('@')[0].split(':')[0]
function addLid (lid, pn) {
  if (!lid || !pn || !/^\d+$/.test(userOf(pn))) return
  upLid.run(`${userOf(lid)}@lid`, `${userOf(pn)}@s.whatsapp.net`)
}
function addLidPair (a, b) {
  if (a?.endsWith('@lid') && b?.endsWith('@s.whatsapp.net')) addLid(a, b)
  else if (b?.endsWith('@lid') && a?.endsWith('@s.whatsapp.net')) addLid(b, a)
}
const canon = (j) => canonJid(db, j)

// ---- Presença (digitando / gravando), só observada e só em conversas privadas.
// A assinatura é feita sob demanda pelo app Zap Privado; nada é gravado no banco.
const presence = new Map()
const presenceSubscribed = new Set()
const isDirectJid = (j) => !!j && !String(j).includes('@g.us') && !String(j).includes('@broadcast') && !String(j).includes('@newsletter')

// ---- Lidas: guarda até quando eu já li cada conversa (recibo "read-self" dos meus outros aparelhos,
// "marcar como lida/não lida" do app state). Só observa, a ponte continua sem marcar nada como lido.
const upRead = db.prepare(`INSERT INTO reads (jid, read_ts, marked_unread) VALUES (?, ?, 0)
  ON CONFLICT(jid) DO UPDATE SET read_ts = MAX(reads.read_ts, excluded.read_ts), marked_unread = 0`)
const upUnread = db.prepare(`INSERT INTO reads (jid, read_ts, marked_unread) VALUES (?, 0, 1)
  ON CONFLICT(jid) DO UPDATE SET marked_unread = 1`)
const maxTsOf = db.prepare('SELECT MAX(ts) AS t FROM messages WHERE chat_jid = ?')
function markRead (jid, ts) {
  if (!jid || jid.endsWith('@broadcast') || jid.endsWith('@newsletter')) return
  const chat = canon(jidNormalizedUser(jid))
  upRead.run(chat, Math.floor(Number(ts) || Date.now() / 1000))
}
// primeira vez: tudo que já existe conta como lido (não temos histórico de leitura)
if (!db.prepare("SELECT v FROM kv WHERE k = 'reads_boot'").get()) {
  const t = Math.floor(Date.now() / 1000)
  db.exec('BEGIN')
  for (const { jid } of db.prepare('SELECT jid FROM chats').all()) upRead.run(jid, t)
  db.exec('COMMIT')
  setKv.run('reads_boot', String(t))
}
function loadLidFiles () {
  const dir = path.join(DATA, 'auth'); let n = 0
  db.exec('BEGIN')
  try {
    for (const f of readdirSync(dir)) {
      const m = f.match(/^lid-mapping-(\d+)_reverse\.json$/); if (!m) continue
      try { const pn = JSON.parse(readFileSync(path.join(dir, f), 'utf8')); if (pn) { addLid(m[1], String(pn)); n++ } } catch {}
    }
    db.exec('COMMIT')
  } catch (e) { db.exec('ROLLBACK'); log.warn(e, 'lid files') }
  return n
}
function mergeLidChats () {
  const rows = db.prepare('SELECT c.jid AS lid, m.pn FROM chats c JOIN lid_map m ON m.lid = c.jid').all()
  db.exec('BEGIN')
  try {
    for (const { lid, pn } of rows) {
      const c = db.prepare('SELECT * FROM chats WHERE jid = ?').get(lid)
      upChat.run(pn, c.name, c.is_group, c.last_ts)
      db.prepare('UPDATE OR IGNORE messages SET chat_jid = ? WHERE chat_jid = ?').run(pn, lid)
      db.prepare('DELETE FROM messages WHERE chat_jid = ?').run(lid)
      db.prepare('UPDATE drafts SET chat_jid = ? WHERE chat_jid = ?').run(pn, lid)
      db.prepare('DELETE FROM chats WHERE jid = ?').run(lid)
      const ct = db.prepare('SELECT name, notify FROM contacts WHERE jid = ?').get(lid)
      const has = db.prepare("SELECT COALESCE(NULLIF(name,''), NULLIF(notify,'')) AS n FROM contacts WHERE jid = ?").get(pn)
      if (ct && !has?.n) upContact.run(pn, ct.name, ct.notify)
    }
    db.prepare('UPDATE messages SET sender_jid = (SELECT pn FROM lid_map WHERE lid = messages.sender_jid) WHERE sender_jid IN (SELECT lid FROM lid_map)').run()
    db.exec('COMMIT')
  } catch (e) { db.exec('ROLLBACK'); log.error(e, 'merge lid'); return }
  if (rows.length) console.log(`Unificadas ${rows.length} conversas LID → número.`)
}
let mergeTimer = null
const scheduleMerge = () => { clearTimeout(mergeTimer); mergeTimer = setTimeout(mergeLidChats, 2000) }

// v7: contatos/conversas podem vir com LID e telefone; grava o nome nos dois ids.
function saveContact (c) {
  const name = c.name || c.verifiedName || null, notify = c.notify || null
  for (const j of new Set([c.id, c.lid, c.phoneNumber, c.jid].filter(Boolean))) upContact.run(jidNormalizedUser(j), name, notify)
}
// arquivar/desarquivar (vem do celular via app state, ou do histórico)
function saveArchived (c) {
  if (!c?.id || typeof c.archived !== 'boolean') return
  upArchived.run(canon(jidNormalizedUser(c.id)), c.archived ? 1 : 0)
}

// Quem já estava arquivado antes desta versão: pede uma vez o estado completo (snapshot) da coleção
// regular_low, onde o WhatsApp guarda o "arquivar". Durante isso ignora os eventos de lido/não lido.
let soArquivo = false
async function lerArquivadasUmaVez () {
  if (getKv('archived_snapshot_v1') || !sock || !connected) return
  soArquivo = true
  try {
    await sock.authState.keys.set({ 'app-state-sync-version': { regular_low: null } })
    await sock.resyncAppState(['regular_low'], false)
    setKv.run('archived_snapshot_v1', String(nowS()))
    const n = db.prepare('SELECT COUNT(*) n FROM chats WHERE archived = 1').get().n
    console.log(`Arquivadas: ${n} conversas.`)
  } finally { setTimeout(() => { soArquivo = false }, 20000) }
}

function saveChat (c) {
  if (!c.id) return
  saveArchived(c)
  const ts = num(c.conversationTimestamp), g = isJidGroup(c.id) ? 1 : 0
  upChat.run(jidNormalizedUser(c.id), c.name || null, g, ts)
  if (c.name && !g) for (const j of [c.pnJid, c.lidJid].filter(Boolean)) upContact.run(jidNormalizedUser(j), c.name, null)
}

const TYPE_LABEL = {
  imageMessage: '[imagem]', videoMessage: '[vídeo]', audioMessage: '[áudio]', stickerMessage: '[figurinha]',
  documentMessage: '[documento]', locationMessage: '[localização]', contactMessage: '[contato]',
  contactsArrayMessage: '[contatos]', pollCreationMessage: '[enquete]', pollCreationMessageV3: '[enquete]',
  liveLocationMessage: '[localização ao vivo]'
}
const SKIP = new Set(['protocolMessage', 'senderKeyDistributionMessage', 'reactionMessage', 'pollUpdateMessage', 'messageContextInfo'])

// Prefere o número de telefone (s.whatsapp.net) ao LID quando os dois existem.
function pick (jid, alt) {
  jid = jid ? jidNormalizedUser(jid) : jid; alt = alt ? jidNormalizedUser(alt) : alt
  addLidPair(jid, alt)
  if (alt && alt.endsWith('@s.whatsapp.net')) return alt
  return canon(jid)
}

const MEDIA_TYPES = new Set(['imageMessage', 'audioMessage', 'videoMessage', 'documentMessage', 'stickerMessage'])
const AUTO_DL = new Set(['imageMessage', 'audioMessage', 'documentMessage'])
const EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'audio/ogg': 'ogg', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'video/mp4': 'mp4', 'application/pdf': 'pdf' }

// Baixa a mídia de uma mensagem salva (usa o "raw" guardado). Retorna { path, mimetype }.
async function downloadMedia (chat, id) {
  const row = db.prepare('SELECT raw, media_path, type FROM messages WHERE chat_jid = ? AND id = ?').get(chat, id)
  if (!row) throw new Error('mensagem não encontrada')
  if (row.media_path && existsSync(row.media_path)) {
    const m = row.raw ? JSON.parse(row.raw, BufferJSON.reviver) : null
    return { path: row.media_path, mimetype: m ? (normalizeMessageContent(m.message)?.[row.type]?.mimetype || null) : null }
  }
  if (!row.raw) throw new Error('mídia antiga, de antes da ponte guardar mídia — não dá pra baixar')
  if (!sock || !connected) throw new Error('WhatsApp desconectado')
  const msg = JSON.parse(row.raw, BufferJSON.reviver)
  const c = normalizeMessageContent(msg.message)?.[row.type] || {}
  const mime = (c.mimetype || '').split(';')[0].trim()
  let ext = EXT[mime] || (mime.split('/')[1] || 'bin').replace(/[^a-z0-9]/gi, '').slice(0, 5)
  if (row.type === 'documentMessage' && c.fileName && c.fileName.includes('.')) ext = c.fileName.split('.').pop().replace(/[^a-z0-9]/gi, '').slice(0, 6)
  const buf = await downloadMediaMessage(msg, 'buffer', {}, { logger: log, reuploadRequest: sock.updateMediaMessage })
  const file = path.join(MEDIA, `${id.replace(/[^A-Za-z0-9_-]/g, '')}.${ext}`)
  writeFileSync(file, buf, { mode: 0o600 })
  db.prepare('UPDATE messages SET media_path = ? WHERE chat_jid = ? AND id = ?').run(file, chat, id)
  return { path: file, mimetype: mime || null }
}

// chave original de cada mensagem recebida (remoteJid/participant como o WhatsApp mandou, @lid ou número):
// o recibo de leitura precisa dela exata. Guarda as últimas ~6000.
const msgKeys = new Map()
function lembrarChave (chat, key) {
  if (key.fromMe || !key.id) return
  msgKeys.set(`${chat}|${key.id}`, { remoteJid: key.remoteJid, id: key.id, participant: key.participant || undefined, fromMe: false })
  if (msgKeys.size > 6000) msgKeys.delete(msgKeys.keys().next().value)
}

function saveMessage (m) {
  const key = m.key || {}
  if (!key.remoteJid || key.remoteJid === 'status@broadcast' || key.remoteJid.endsWith('@newsletter')) return
  const content = normalizeMessageContent(m.message)
  if (!content) return
  const type = getContentType(content)
  if (!type || SKIP.has(type)) return
  const c = content[type] || {}
  let text = content.conversation || c.text || c.caption || null
  const label = TYPE_LABEL[type]
  if (label) text = text ? `${label} ${text}` : (type === 'documentMessage' && c.fileName ? `${label} ${c.fileName}` : label)
  if (!text) text = `[${type}]`
  const chat = pick(key.remoteJid, key.remoteJidAlt)
  const group = isJidGroup(chat) ? 1 : 0
  const sender = key.fromMe ? 'me' : pick(key.participant || key.remoteJid, key.participantAlt || key.remoteJidAlt)
  const ts = num(m.messageTimestamp)
  const raw = MEDIA_TYPES.has(type) ? JSON.stringify(m, BufferJSON.replacer) : null
  upMsg.run(chat, key.id, sender, key.fromMe ? 1 : 0, ts, type, text, m.pushName || null, raw)
  lembrarChave(chat, key)
  upChat.run(chat, null, group, ts)
  if (!key.fromMe && m.pushName && sender) upContact.run(sender, null, m.pushName)
  return { chat, id: key.id, type, size: num(c.fileLength) }
}

// Conversas salvas como @lid sem nome: descobre o telefone e copia o nome do contato.
async function backfillLidNames () {
  const map = sock?.signalRepository?.lidMapping
  if (!map?.getPNForLID) return
  const rows = db.prepare(`SELECT c.jid FROM chats c LEFT JOIN contacts ct ON ct.jid = c.jid
    WHERE c.jid LIKE '%@lid' AND COALESCE(NULLIF(c.name,''), NULLIF(ct.name,''), NULLIF(ct.notify,'')) IS NULL`).all()
  let n = 0
  for (const { jid } of rows) {
    const pn = await map.getPNForLID(jid).catch(() => null)
    if (!pn) continue
    addLid(jid, pn)
    const ct = db.prepare('SELECT name, notify FROM contacts WHERE jid = ?').get(jidNormalizedUser(pn))
    if (ct?.name || ct?.notify) { upContact.run(jid, ct.name, ct.notify); n++ } else { upContact.run(jid, null, pn.split('@')[0].split(':')[0]); n++ }
  }
  if (rows.length) console.log(`Nomes LID: ${n}/${rows.length} resolvidos.`)
}

let sock = null
let connected = false
// ---- Saúde da ponte (25/11): motivo de cada queda, sono do Mac e última msg recebida, expostos no /status.
const hora = () => new Date().toLocaleString('pt-BR')
const MOTIVOS = {
  401: 'sessão encerrada no celular', 403: 'acesso negado pelo WhatsApp', 408: 'tempo esgotado (internet ou Mac dormindo)',
  411: 'versão de aparelho incompatível', 428: 'conexão fechada (internet ou Mac dormindo)', 440: 'outra ponte abriu com a mesma sessão',
  500: 'sessão corrompida', 503: 'erro passageiro no servidor do WhatsApp', 515: 'reinício pedido pelo WhatsApp (normal)'
}
let connectedSince = 0, lastRx = 0, ultimaQueda = null, ultimoSono = null
let relogio = Date.now()
setInterval(() => {
  const agora = Date.now(), pulo = agora - relogio
  relogio = agora
  if (pulo > 60e3) { // o processo ficou congelado: Mac dormiu
    ultimoSono = { de: Math.floor((agora - pulo) / 1000), ate: Math.floor(agora / 1000) }
    console.log(`[${hora()}] Mac dormiu por ~${Math.round(pulo / 60e3)} min (processo congelado), a conexão vai se refazer.`)
    try { setKv.run('ultimo_sono', JSON.stringify(ultimoSono)) } catch {}
  }
}, 10e3).unref()

// ---- Batimento + buracos: a ponte grava "heartbeat" a cada 30s enquanto conectada.
// Ao reconectar, se o último batimento for antigo, registra o período fora em kv.gaps.
const getKv = (k) => db.prepare('SELECT v FROM kv WHERE k = ?').get(k)?.v
const nowS = () => Math.floor(Date.now() / 1000)
const GAP_MIN = 120
function readGaps () { try { return JSON.parse(getKv('gaps') || '[]') } catch { return [] } }
function recordGap () {
  const prev = Number(getKv('heartbeat') || 0), t = nowS()
  if (prev && t - prev > GAP_MIN) {
    const gaps = readGaps(); gaps.push({ from: prev, to: t })
    setKv.run('gaps', JSON.stringify(gaps.slice(-30)))
    console.log(`[${hora()}] Buraco registrado: ponte fora de ${new Date(prev * 1000).toLocaleString('pt-BR')} até ${new Date(t * 1000).toLocaleString('pt-BR')}.`)
  }
}
const beat = () => { if (connected) setKv.run('heartbeat', String(nowS())) }
setInterval(beat, 30e3).unref()

// ---- Recuperar buraco: pede ao celular o histórico ANTES da primeira mensagem salva depois do buraco
// (o WhatsApp só busca "pra trás" a partir de uma mensagem conhecida).
const gapKey = (chat, g) => `gf:${chat}:${g.from}`
let histWaiters = []
function gapAnchor (chat) {
  for (const g of readGaps().reverse()) {
    if (nowS() - g.to > 14 * 86400) break
    if (getKv(gapKey(chat, g))) continue
    const a = db.prepare('SELECT id, from_me, ts FROM messages WHERE chat_jid = ? AND ts >= ? ORDER BY ts LIMIT 1').get(chat, g.to)
    if (a) return { g, a }
  }
  return null
}
// Fila: um pedido por vez, com intervalo, pra não martelar o celular.
let histQueue = Promise.resolve()
function fillGap (chat, { wait = 0 } = {}) {
  const job = histQueue.then(async () => {
    if (!sock || !connected) return { ok: false, reason: 'desconectado' }
    const found = gapAnchor(chat)
    if (!found) return { ok: false, reason: 'sem buraco pendente com âncora' }
    const { g, a } = found
    const before = db.prepare('SELECT COUNT(*) AS n FROM messages WHERE chat_jid = ? AND ts > ? AND ts < ?').get(chat, g.from, a.ts).n
    const got = new Promise((resolve) => {
      const w = { chat, resolve }; histWaiters.push(w)
      setTimeout(() => { histWaiters = histWaiters.filter(x => x !== w); resolve(false) }, wait || 15e3)
    })
    await sock.fetchMessageHistory(50, { remoteJid: chat, fromMe: !!a.from_me, id: a.id }, a.ts * 1000)
    const arrived = await got
    const after = db.prepare('SELECT COUNT(*) AS n FROM messages WHERE chat_jid = ? AND ts > ? AND ts < ?').get(chat, g.from, a.ts).n
    setKv.run(gapKey(chat, g), String(nowS()))
    if (after > before) console.log(`Buraco preenchido em ${chat}: +${after - before} mensagens.`)
    await new Promise(r => setTimeout(r, 1500))
    return { ok: true, respondeu: arrived, novas: after - before }
  }).catch((e) => { log.warn(e, 'fillGap'); return { ok: false, reason: String(e?.message || e) } })
  histQueue = job.then(() => {}, () => {})
  return job
}

async function start () {
  const { state, saveCreds } = await useMultiFileAuthState(path.join(DATA, 'auth'))
  const { version } = await fetchLatestBaileysVersion().catch(() => ({ version: undefined }))
  sock = makeWASocket({
    version, auth: state, logger: log,
    browser: Browsers.macOS('Desktop'),
    markOnlineOnConnect: false, // não "rouba" as notificações do celular
    syncFullHistory: false,
    shouldSyncHistoryMessage: () => true
  })
  sock.ev.on('creds.update', saveCreds)

  // "typing" e "recording" chegam aqui; "paused"/"available" encerram o estado.
  sock.ev.on('presence.update', ({ presences }) => {
    for (const [who, p] of Object.entries(presences || {})) {
      const jid = canon(who)
      if (!isDirectJid(jid)) continue
      const s = p?.lastKnownPresence
      if (s === 'composing' || s === 'typing') presence.set(jid, { state: 'typing', at: Date.now() })
      else if (s === 'recording') presence.set(jid, { state: 'recording', at: Date.now() })
      else presence.delete(jid)
    }
  })

  sock.ev.on('connection.update', async ({ connection, lastDisconnect, qr }) => {
    if (qr) {
      const png = path.join(DATA, 'qr.png')
      await QRCode.toFile(png, qr, { width: 420, margin: 2 })
      console.log(await QRCode.toString(qr, { type: 'terminal', small: true }))
      console.log(`\nEscaneie no celular: WhatsApp > Aparelhos conectados > Conectar aparelho.\n(QR também salvo em ${png})`)
      if (process.platform === "darwin" && process.env.WA_OPEN_QR) execFile('open', [png])
    }
    if (connection === 'open') {
      presence.clear()
      presenceSubscribed.clear()
      recordGap()
      connected = true
      connectedSince = Math.floor(Date.now() / 1000)
      beat()
      setKv.run('status', 'conectado'); setKv.run('me', jidNormalizedUser(sock.user?.id || ''))
      rmSync(path.join(DATA, 'qr.png'), { force: true })
      console.log(`[${hora()}] Conectado como ${sock.user?.id}.`)
      try {
        const groups = await sock.groupFetchAllParticipating()
        for (const g of Object.values(groups)) upChat.run(g.id, g.subject || null, 1, 0)
      } catch (e) { log.warn(e, 'groupFetch') }
      console.log(`Mapa LID: ${loadLidFiles()} números.`)
      // espera o backlog offline assentar antes de pedir o snapshot
      setTimeout(() => lerArquivadasUmaVez().catch((e) => log.warn(e, 'arquivadas')), 60000)
      backfillLidNames().catch((e) => log.warn(e, 'lid backfill')).finally(mergeLidChats)
    }
    if (connection === 'close') {
      connected = false
      const code = lastDisconnect?.error?.output?.statusCode
      const msg = String(lastDisconnect?.error?.message || lastDisconnect?.error || '').slice(0, 200)
      const dormiu = ultimoSono && Date.now() / 1000 - ultimoSono.ate < 120
      const motivo = dormiu ? 'Mac dormiu' : (MOTIVOS[code] || 'motivo desconhecido')
      ultimaQueda = { at: Math.floor(Date.now() / 1000), code: code ?? null, motivo, msg, conectadoDesde: connectedSince || null }
      connectedSince = 0
      setKv.run('ultima_queda', JSON.stringify(ultimaQueda))
      console.log(`[${hora()}] CONEXÃO FECHOU: código ${code ?? '?'} · ${motivo}${msg ? ` · ${msg}` : ''}`)
      setKv.run('status', `desconectado (${code ?? '?'})`)
      if (code === DisconnectReason.loggedOut) {
        console.error('Sessão encerrada no celular. Gerando um QR novo.')
        setKv.run('status', 'sessão encerrada no celular (precisa novo QR)')
        // Sísifo: limpa a sessão e volta a mostrar QR (o app mostra na tela de conectar)
        rmSync(path.join(DATA, 'auth'), { recursive: true, force: true })
        setTimeout(start, 1000)
        return
      }
      setTimeout(start, code === DisconnectReason.restartRequired ? 0 : 3000)
    }
  })

  sock.ev.on('messaging-history.set', ({ chats = [], contacts = [], messages = [], syncType }) => {
    db.exec('BEGIN')
    try {
      for (const c of contacts) saveContact(c)
      for (const c of chats) saveChat(c)
      for (const m of messages) saveMessage(m)
      db.exec('COMMIT')
    } catch (e) { db.exec('ROLLBACK'); log.error(e, 'history') }
    console.log(`Histórico${syncType === 6 ? ' (sob demanda)' : ''}: +${messages.length} mensagens, ${chats.length} conversas.`)
    scheduleMerge()
    if (syncType === 6 && histWaiters.length) {
      const chatsIn = new Set(messages.map(m => { try { return pick(m.key?.remoteJid, m.key?.remoteJidAlt) } catch { return null } }))
      for (const w of histWaiters.filter(w => chatsIn.has(w.chat) || !messages.length)) w.resolve(true)
      histWaiters = histWaiters.filter(w => !(chatsIn.has(w.chat) || !messages.length))
    }
  })
  sock.ev.on('messages.upsert', ({ messages, type }) => {
    if (type === 'notify') lastRx = Math.floor(Date.now() / 1000)
    if (process.env.WA_DBG) console.log('UPSERT', type, messages.length, JSON.stringify(messages.map(m => [m.key?.remoteJid, m.key?.fromMe, m.messageStubType, Object.keys(m.message || {})])))
    for (const m of messages) {
      try {
        const r = saveMessage(m)
        // Mensagem nova numa conversa que teve buraco: tenta recuperar o que faltou.
        if (r && type === 'notify' && gapAnchor(r.chat)) setTimeout(() => fillGap(r.chat), 3000)
        // Mídia nova (imagem/áudio/documento até 25 MB) já baixa na hora; o resto sob demanda.
        if (r && AUTO_DL.has(r.type) && (!r.size || r.size < 25e6)) downloadMedia(r.chat, r.id).catch((e) => log.warn(e, 'auto media'))
      } catch (e) { log.error(e) }
    }
  })
  sock.ev.on('contacts.upsert', (cs) => { for (const c of cs) saveContact(c) })
  sock.ev.on('contacts.update', (cs) => { for (const c of cs) if (c.id) saveContact(c) })
  sock.ev.on('chats.upsert', (cs) => { for (const c of cs) saveChat(c) })
  sock.ev.on('chats.update', (cs) => {
    for (const c of cs) {
      if (c.name) saveChat(c)
      saveArchived(c)
      if (soArquivo) continue // releitura do estado de arquivadas: não mexe em lido/não lido
      // marcou como lida em outro aparelho = leu tudo até agora; -1 = "marcar como não lida"
      if (c.id && c.unreadCount === 0) markRead(c.id, Math.max(Date.now() / 1000, maxTsOf.get(canon(jidNormalizedUser(c.id))).t || 0))
      else if (c.id && c.unreadCount === -1) upUnread.run(canon(jidNormalizedUser(c.id)))
    }
  })
  // recibo de leitura dos MEUS aparelhos (celular, ZapFast…): li a conversa até esse momento
  sock.ws.on('CB:receipt', (node) => {
    try {
      const a = node?.attrs || {}
      if (a.type !== 'read-self') return
      const chat = isJidGroup(a.from) ? a.from : (a.recipient || a.from)
      if (process.env.WA_DBG) console.log('READ-SELF', a.from, a.recipient, a.participant, a.t)
      markRead(chat, a.t)
    } catch (e) { log.warn(e, 'read-self') }
  })
  sock.ev.on('lid-mapping.update', (m) => {
    for (const x of [].concat(m || [])) addLid(x?.lid, x?.pn)
    scheduleMerge()
  })
  sock.ev.on('groups.update', (gs) => { for (const g of gs) if (g.id && g.subject) upChat.run(g.id, g.subject, 1, 0) })
}

// Envio: só localhost + token. Quem decide se envia é o MCP (desligado por padrão).
http.createServer(async (req, res) => {
  const reply = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)) }
  if (req.headers.authorization !== `Bearer ${TOKEN}`) return reply(401, { error: 'token' })
  if (req.method === 'GET' && req.url === '/status') {
    let gaps = []; try { gaps = readGaps().slice(-5) } catch {}
    let queda = ultimaQueda; if (!queda) try { queda = JSON.parse(getKv('ultima_queda') || 'null') } catch {}
    return reply(200, {
      connected, me: sock?.user?.id || null, since: connectedSince || null, lastRx: lastRx || null,
      heartbeat: Number(getKv('heartbeat') || 0) || null, ultimaQueda: queda, ultimoSono, gaps, pid: process.pid, qr: existsSync(path.join(DATA, 'qr.png'))
    })
  }
  // QR atual (PNG) pra tela de conectar do app
  if (req.method === 'GET' && req.url.startsWith('/qr')) {
    const png = path.join(DATA, 'qr.png')
    if (!existsSync(png)) return reply(404, { error: 'sem qr' })
    res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'no-store' })
    return res.end(readFileSync(png))
  }
  // contatos que mais falam nos teus grupos (tela "tua equipe" da primeira abertura)
  if (req.method === 'GET' && req.url === '/contacts') {
    const me = (sock?.user?.id || '').split(':')[0].split('@')[0]
    const since = Math.floor(Date.now() / 1000) - 90 * 86400
    const rows = db.prepare(`SELECT m.sender_jid j, COUNT(*) n, MAX(m.push_name) push FROM messages m
      WHERE m.chat_jid LIKE '%@g.us' AND m.from_me = 0 AND m.sender_jid IS NOT NULL AND m.ts > ? GROUP BY m.sender_jid ORDER BY n DESC LIMIT 400`).all(since)
    const pnOf = db.prepare('SELECT pn FROM lid_map WHERE lid = ?')
    const nameOf = db.prepare("SELECT COALESCE(NULLIF(name,''), NULLIF(notify,'')) n FROM contacts WHERE jid = ?")
    const out = new Map()
    for (const r of rows) {
      const pn = r.j.endsWith('@lid') ? pnOf.get(r.j)?.pn : r.j
      if (!pn || !pn.endsWith('@s.whatsapp.net')) continue
      const numero = pn.split('@')[0]
      if (numero === me || out.has(numero)) continue
      const nome = nameOf.get(pn)?.n || nameOf.get(r.j)?.n || r.push || '+' + numero
      out.set(numero, { nome, numero })
      if (out.size >= 150) break
    }
    return reply(200, [...out.values()])
  }
  // desconectar (tela de ajustes): sai da conta e gera QR novo
  if (req.method === 'POST' && req.url === '/logout') {
    try { await sock?.logout() } catch {}
    rmSync(path.join(DATA, 'auth'), { recursive: true, force: true })
    setTimeout(start, 500)
    return reply(200, { ok: true })
  }
  // Só leitura: presença da conversa atual (digitando / gravando). Nada é persistido.
  if (req.method === 'GET' && req.url.startsWith('/presence?jid=')) {
    if (!connected) return reply(503, { error: 'WhatsApp desconectado' })
    const jid = canon(new URL(req.url, 'http://x').searchParams.get('jid') || '')
    if (!isDirectJid(jid)) return reply(400, { error: 'só conversas privadas' })
    if (!presenceSubscribed.has(jid)) {
      presenceSubscribed.add(jid)
      sock.presenceSubscribe(jid).catch(() => presenceSubscribed.delete(jid))
    }
    const p = presence.get(jid)
    const state = p && Date.now() - p.at < 15000 ? p.state : null
    return reply(200, { jid, presence: state, typing: state === 'typing', recording: state === 'recording' })
  }
  // Só leitura: info de um link de convite (nome, tamanho) sem entrar no grupo
  if (req.method === 'GET' && req.url.startsWith('/invite?code=')) {
    const code = decodeURIComponent(req.url.split('=')[1] || '')
    return sock.groupGetInviteInfo(code)
      .then((g) => reply(200, { subject: g.subject, size: g.size, participants: g.participants?.length, restrict: g.restrict, announce: g.announce, joinApprovalMode: g.joinApprovalMode, memberAddMode: g.memberAddMode }))
      .catch((e) => reply(500, { error: String(e?.message || e), data: e?.data }))
  }
  // Só leitura: participantes de um grupo
  if (req.method === 'GET' && req.url.startsWith('/group?jid=')) {
    if (!connected) return reply(503, { error: 'WhatsApp desconectado' })
    const jid = decodeURIComponent(req.url.split('=')[1] || '')
    return sock.groupMetadata(jid)
      .then((g) => reply(200, { subject: g.subject, participants: (g.participants || []).map((p) => ({ id: p.id, pn: p.phoneNumber || p.jid || null, lid: p.lid || null })) }))
      .catch((e) => reply(404, { error: String(e?.message || e) }))
  }
  // Só leitura: URL da foto de perfil/grupo (usado pelo app Zap Pendente)
  if (req.method === 'GET' && req.url.startsWith('/avatar?jid=')) {
    if (!connected) return reply(503, { error: 'WhatsApp desconectado' })
    const jid = canon(decodeURIComponent(req.url.split('=')[1] || ''))
    return sock.profilePictureUrl(jid, 'image')
      .then((url) => (url ? reply(200, { url }) : reply(404, { error: 'sem foto' })))
      .catch((e) => reply(404, { error: String(e?.message || e) }))
  }
  if (req.method !== 'POST' || !['/send', '/sticker', '/media', '/delete-chat', '/history', '/read'].includes(req.url)) return reply(404, { error: 'rota' })
  let body = ''
  req.on('data', (d) => { body += d; if (body.length > 1e5) req.destroy() })
  req.on('end', async () => {
    if (req.url === '/history') {
      // Sob demanda (ler_mensagens): tenta recuperar o buraco desta conversa e espera até 10s.
      try {
        const { chat } = JSON.parse(body)
        return reply(200, await fillGap(canon(chat), { wait: 10e3 }))
      } catch (e) { return reply(500, { error: String(e?.message || e) }) }
    }
    if (req.url === '/delete-chat') {
      // Apaga a conversa no WhatsApp (todos os aparelhos). Precisa da última mensagem conhecida.
      try {
        const { jid } = JSON.parse(body)
        if (!connected) return reply(503, { error: 'WhatsApp desconectado' })
        const chat = canon(jid)
        const last = db.prepare('SELECT id, from_me, ts, sender_jid FROM messages WHERE chat_jid = ? ORDER BY ts DESC LIMIT 1').get(chat)
        // Sem mensagem salva: manda o delete sem âncora (apaga até agora).
        const lastMessages = last ? [{ key: { remoteJid: chat, id: last.id, fromMe: !!last.from_me }, messageTimestamp: last.ts }] : []
        await sock.chatModify({ delete: true, lastMessages }, chat)
        db.prepare('DELETE FROM messages WHERE chat_jid = ?').run(chat)
        db.prepare('DELETE FROM chats WHERE jid = ?').run(chat)
        return reply(200, { ok: true })
      } catch (e) { return reply(500, { error: String(e?.message || e) }) }
    }
    if (req.url === '/read') {
      // Marca a conversa como lida no WhatsApp (azulzinho pra quem mandou, some o contador no celular).
      // Só quando a pessoa liga "Marcar como lido no WhatsApp" no Sísifo.
      try {
        const { jid } = JSON.parse(body)
        if (!connected) return reply(503, { error: 'WhatsApp desconectado' })
        const chat = canon(jid)
        const desde = Number(db.prepare('SELECT read_ts FROM reads WHERE jid = ?').get(chat)?.read_ts || 0)
        const rows = db.prepare(`SELECT id, sender_jid, ts FROM messages WHERE chat_jid = ? AND from_me = 0 AND ts > ? AND ts > ?
          ORDER BY ts DESC LIMIT 60`).all(chat, desde, Math.floor(Date.now() / 1000) - 7 * 86400)
        const grupo = chat.endsWith('@g.us')
        const lidOf = db.prepare('SELECT lid FROM lid_map WHERE pn = ?')
        const keys = rows.map((r) => msgKeys.get(`${chat}|${r.id}`) || {
          remoteJid: chat, id: r.id, fromMe: false,
          participant: grupo ? (lidOf.get(r.sender_jid)?.lid || r.sender_jid || undefined) : undefined,
        })
        if (keys.length) await sock.readMessages(keys)
        // tira o "não lida" da conversa nos outros aparelhos (celular), ancorado na última mensagem
        if (keys.length) { try { await sock.chatModify({ markRead: true, lastMessages: [{ key: keys[0], messageTimestamp: rows[0].ts }] }, keys[0].remoteJid) } catch (e) { log.warn(e, 'markRead') } }
        markRead(chat, Date.now() / 1000)
        return reply(200, { ok: true, n: keys.length })
      } catch (e) { return reply(500, { error: String(e?.message || e) }) }
    }
    if (req.url === '/media') {
      try {
        const { chat, id } = JSON.parse(body)
        return reply(200, await downloadMedia(canon(chat), id))
      } catch (e) { return reply(500, { error: String(e?.message || e) }) }
    }
    if (req.url === '/sticker') {
      // Figurinha: WebP local (é o formato que o WhatsApp usa pra sticker)
      try {
        const { jid, file } = JSON.parse(body)
        if (!connected) return reply(503, { error: 'WhatsApp desconectado' })
        if (!jid || !file || !existsSync(file)) return reply(400, { error: 'jid e arquivo da figurinha obrigatórios' })
        if (!/\.webp$/i.test(file)) return reply(400, { error: 'figurinha precisa ser .webp' })
        const sent = await sock.sendMessage(canon(jid), { sticker: readFileSync(file) })
        saveMessage(sent)
        return reply(200, { ok: true, id: sent?.key?.id })
      } catch (e) { return reply(500, { error: String(e?.message || e) }) }
    }
    try {
      const { jid, text, file, quoted } = JSON.parse(body)
      if (!connected) return reply(503, { error: 'WhatsApp desconectado' })
      if (!jid || (!text && !file)) return reply(400, { error: 'jid e text ou file obrigatórios' })
      let content = { text }
      // Menções: "@5511999999999" no texto vira menção de verdade. Em grupo com LID, troca pelo @lid.
      if (text && /@\d{8,}/.test(text)) {
        const mentions = []
        const lidOf = db.prepare('SELECT lid FROM lid_map WHERE pn = ?')
        const isGroup = canon(jid).endsWith('@g.us')
        const t2 = text.replace(/@(\d{8,})/g, (m, num) => {
          const lid = isGroup ? lidOf.get(`${num}@s.whatsapp.net`)?.lid : null
          const target = lid || `${num}@s.whatsapp.net`
          mentions.push(target)
          return '@' + target.split('@')[0]
        })
        content = { text: t2, mentions }
      }
      if (file) {
        // Arquivo local: imagem vai como foto (legenda = text), resto como documento.
        if (!existsSync(file)) return reply(400, { error: `arquivo não existe: ${file}` })
        const ext = path.extname(file).slice(1).toLowerCase()
        const buf = readFileSync(file)
        if (['png', 'jpg', 'jpeg', 'webp'].includes(ext)) content = { image: buf, caption: text || undefined }
        else if (['mp4', 'mov'].includes(ext)) content = { video: buf, caption: text || undefined }
        // Áudio (Zap Privado arrasta arquivo): ogg/opus vira mensagem de voz, resto vira áudio comum.
        else if (['ogg', 'opus'].includes(ext)) content = { audio: buf, mimetype: 'audio/ogg; codecs=opus', ptt: true }
        else if (['mp3', 'm4a', 'aac', 'wav'].includes(ext)) content = { audio: buf, mimetype: { mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', wav: 'audio/wav' }[ext] }
        else content = { document: buf, fileName: path.basename(file), mimetype: ext === 'pdf' ? 'application/pdf' : 'application/octet-stream', caption: text || undefined }
      }
      // Resposta citada (dois cliques no balão no Zap Privado). Conversa privada, ou grupo com participant (quem mandou).
      const opts = {}
      const qGrupo = quoted && quoted.jid && canon(quoted.jid).endsWith('@g.us')
      if (quoted && quoted.id && (isDirectJid(quoted.jid) || (qGrupo && (quoted.participant || quoted.me)))) {
        const key = { remoteJid: canon(quoted.jid), fromMe: !!quoted.me, id: quoted.id }
        if (qGrupo && quoted.participant) key.participant = quoted.participant
        opts.quoted = { key, message: { conversation: String(quoted.text || 'Mensagem').slice(0, 300) } }
      }
      const sent = await sock.sendMessage(canon(jid), content, opts)
      saveMessage(sent)
      reply(200, { ok: true, id: sent?.key?.id })
    } catch (e) { reply(500, { error: String(e?.message || e) }) }
  })
}).listen(PORT, '127.0.0.1', () => console.log(`Ponte ouvindo em 127.0.0.1:${PORT}`))

process.on('SIGINT', () => { setKv.run('status', 'parado'); process.exit(0) })
process.on('SIGTERM', () => { console.log(`[${hora()}] Ponte parada (SIGTERM, reinício pedido).`); setKv.run('status', 'parado'); process.exit(0) })
console.log(`[${hora()}] Ponte iniciando (pid ${process.pid}).`)
// Erro solto não derruba a ponte em silêncio: loga e sai com código 1 → launchd reinicia.
process.on('uncaughtException', (e) => { console.error('uncaughtException', e); setKv.run('status', 'caiu (reiniciando)'); process.exit(1) })
process.on('unhandledRejection', (e) => { log.error(e, 'unhandledRejection') })
start()
