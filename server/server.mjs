// Sísifo · demandas: lê o banco da ponte do WhatsApp (só leitura), usa o Claude local
// pra tirar os PEDIDOS DE TRABALHO das conversas, e serve pro app em 127.0.0.1 (porta em config.mjs).
// Só envia no WhatsApp quando eu clico "enviar" numa resposta (rota /reply → ponte).
import http from 'node:http'
import { DatabaseSync } from 'node:sqlite'
import { execFile } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync, appendFileSync, unlinkSync, readdirSync, openSync, readSync, closeSync } from 'node:fs'
import { createHash } from 'node:crypto'
import os from 'node:os'
import path from 'node:path'

import { HOME, APP_PORT, DB_PATH, TOKEN_PATH, BRIDGE, CLAUDE, WA_DATA, nome, papel, equipeTxt } from './config.mjs'
const PORT = APP_PORT
const DIR = path.join(HOME, 'demandas')
const AVATARS = path.join(DIR, 'avatars')
const STATE_FILE = path.join(DIR, 'demandas.json')
const LOG_FILE = path.join(DIR, 'decisoes.jsonl')
// espera o WhatsApp conectar pela primeira vez (o banco só existe depois disso)
while (!existsSync(DB_PATH)) await new Promise((r) => setTimeout(r, 2000))
const WINDOW_H = 72
const MODEL = process.env.ZAP_MODEL || 'sonnet'
mkdirSync(AVATARS, { recursive: true })

const log = (...a) => console.log(new Date().toISOString(), ...a)
const now = () => Math.floor(Date.now() / 1000)
mkdirSync(DIR, { recursive: true })
const db = new DatabaseSync(DB_PATH, { readOnly: true })
db.exec('PRAGMA busy_timeout = 5000')

// estado: demandas, quando cada conversa foi lida, exemplos de "não é demanda", conversas silenciadas
let st = { demands: {}, scanned: {}, ignored: [], muted: {}, booted: false, clients: {} }
try { st = { ...st, ...JSON.parse(readFileSync(STATE_FILE, 'utf8')) } } catch {}

// mesmo cliente sempre com o mesmo nome ("Loja X" = "LojaX")
const KNOWN = []   // nomes de clientes aprendidos sozinhos conforme aparecem
const normKey = (n) => String(n || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '')
for (const k of KNOWN) st.clients[normKey(k)] ??= k
function canonClient (name) {
  const k = normKey(name)
  if (!k) return name
  if (!st.clients[k]) st.clients[k] = String(name).trim()
  return st.clients[k]
}
for (const d of Object.values(st.demands)) d.client = canonClient(d.client)
let saveT = null
const save = () => { clearTimeout(saveT); saveT = setTimeout(() => { try { writeFileSync(STATE_FILE, JSON.stringify(st), { mode: 0o600 }) } catch {} }, 300) }

// log local de tudo que tu decide (feito, não é demanda, passar pra…) e do que o leitor pulou.
// Uma linha JSON por evento em decisoes.jsonl, só neste Mac.
function decide (action, d, extra = {}) {
  try {
    appendFileSync(LOG_FILE, JSON.stringify({ at: new Date().toISOString(), action, id: d?.id, jid: d?.jid, msgId: d?.msgId, client: d?.client, title: d?.title, ...extra }) + '\n', { mode: 0o600 })
  } catch {}
}
const OWNER_AREA = { eu: 'eu' }   // 'eu' = é comigo; qualquer outro dono = alguém da equipe

const REAL = `('conversation','extendedTextMessage','imageMessage','audioMessage','videoMessage','documentMessage',
  'documentWithCaptionMessage','albumMessage','contactMessage','locationMessage','pollCreationMessage','pollCreationMessageV3')`
const NAME = `COALESCE(NULLIF(c.name,''), NULLIF(ct.name,''), NULLIF(ct.notify,''), c.jid)`
const MEDIA = { imageMessage: '[foto]', audioMessage: '[áudio]', videoMessage: '[vídeo]', documentMessage: '[documento]',
  documentWithCaptionMessage: '[documento]', albumMessage: '[fotos]', contactMessage: '[contato]', locationMessage: '[localização]' }

const meRaw = db.prepare("SELECT v FROM kv WHERE k = 'me'").get()?.v || ''
const MY_IDS = [meRaw.split('@')[0].split(':')[0]]
for (const r of db.prepare('SELECT lid FROM lid_map WHERE pn = ?').all(meRaw)) MY_IDS.push(r.lid.split('@')[0])

function contactName (jid, push) {
  if (!jid) return push || '?'
  const r = db.prepare("SELECT COALESCE(NULLIF(name,''), NULLIF(notify,'')) n FROM contacts WHERE jid = ?").get(jid)
  return r?.n || push || jid.split('@')[0]
}
function pretty (t) {
  return t.replace(/@(\d{8,})/g, (all, id) => {
    if (MY_IDS.includes(id)) return '@' + nome()
    const pn = db.prepare('SELECT pn FROM lid_map WHERE lid = ?').get(id + '@lid')?.pn
    const n = contactName(pn || id + '@s.whatsapp.net', null)
    return /^\d+$/.test(n) ? all : '@' + n.split(' ')[0]
  })
}
// áudios: a ponte só transcreve quando alguém pede pelo MCP, então o Demandas transcreve sozinho
// (whisper local, mesmo modelo da ponte) e guarda em transcripts.json. Sem isso, cliente que só
// manda áudio vira "[áudio]" e a IA não acha demanda nenhuma.
const TR_FILE = path.join(DIR, 'transcripts.json')
const W_MODEL = path.join(WA_DATA, 'models/ggml-small.bin')
const WHISPER = ['/opt/homebrew/bin/whisper-cli', '/usr/local/bin/whisper-cli'].find(existsSync)
const FFMPEG = ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'].find(existsSync)
let TR = {}
try { TR = JSON.parse(readFileSync(TR_FILE, 'utf8')) } catch {}
const runP = (cmd, args) => new Promise((res, rej) => execFile(cmd, args, { maxBuffer: 20e6, timeout: 180e3 }, (e, out, err) => e ? rej(new Error((err || e.message).slice(0, 200))) : res(out)))
async function transcribeAudios (msgs) {
  if (!WHISPER || !FFMPEG || !existsSync(W_MODEL)) return
  let changed = false
  for (const m of msgs) {
    if (m.type !== 'audioMessage' || m.transcript || TR[m.id] || !m.media_path || !existsSync(m.media_path)) continue
    const wav = path.join(os.tmpdir(), `dem-${process.pid}-${Date.now()}.wav`)
    try {
      await runP(FFMPEG, ['-y', '-loglevel', 'error', '-i', m.media_path, '-ar', '16000', '-ac', '1', wav])
      const out = await runP(WHISPER, ['-m', W_MODEL, '-l', 'pt', '-nt', '-np', '-t', '4', '-f', wav])
      TR[m.id] = out.replace(/\s+/g, ' ').trim() || '(áudio sem fala)'
      changed = true
    } catch (e) { log('transcrição falhou', m.id, e.message) } finally { try { unlinkSync(wav) } catch {} }
  }
  if (changed) try { writeFileSync(TR_FILE, JSON.stringify(TR), { mode: 0o600 }) } catch {}
}
function msgText (m) {
  if (m.transcript || TR[m.id]) return `[áudio] ${m.transcript || TR[m.id]}`
  const t = pretty((m.text || '').replace(/\s+/g, ' ').trim())
  if (MEDIA[m.type]) return t && !/^\[.*\]$/.test(t) ? `${MEDIA[m.type]} ${t}` : MEDIA[m.type]
  return t
}
const chatInfo = (jid) => db.prepare(`SELECT c.jid, ${NAME} AS name, c.is_group FROM chats c LEFT JOIN contacts ct ON ct.jid = c.jid WHERE c.jid = ?`).get(jid)
const cleanName = (n) => (n || '').includes('@') ? n.split('@')[0] : n

// conversas com movimento recente (alguém além de mim falou)
function activeChats () {
  const since = now() - WINDOW_H * 3600
  return db.prepare(`
    SELECT m.chat_jid AS jid, MAX(m.ts) AS lastTs FROM messages m
    WHERE m.type IN ${REAL} AND m.ts > ?
      AND m.chat_jid NOT LIKE '%@broadcast' AND m.chat_jid NOT LIKE '%@newsletter'
    GROUP BY m.chat_jid
    HAVING SUM(CASE WHEN m.from_me = 0 THEN 1 ELSE 0 END) > 0
    ORDER BY lastTs DESC LIMIT 40`).all(since).filter((c) => !st.muted[c.jid])
}

function recent (jid, n = 30) {
  const since = now() - WINDOW_H * 3600
  return db.prepare(`SELECT * FROM (SELECT * FROM messages WHERE chat_jid = ? AND type IN ${REAL} AND ts > ? ORDER BY ts DESC LIMIT ?) ORDER BY ts`).all(jid, since - 24 * 3600, n)
}

const fmtDate = (ts) => new Date(ts * 1000).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', weekday: 'short', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })
const dayOf = (ts) => new Date(ts * 1000).toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' })

function askClaude (prompt, model = MODEL) {
  return new Promise((resolve, reject) => {
    if (!CLAUDE) return reject(new Error('claude CLI não encontrado'))
    const cfg = path.join(DIR, 'empty-mcp.json')
    if (!existsSync(cfg)) writeFileSync(cfg, '{"mcpServers":{}}')
    const p = execFile(CLAUDE, ['-p', '--model', model, '--strict-mcp-config', '--mcp-config', cfg, '--tools', ''],
      { timeout: 120e3, maxBuffer: 4e6, cwd: DIR, env: { ...process.env, PATH: `${path.dirname(CLAUDE)}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin` } },
      (err, out, errOut) => (err ? reject(new Error((errOut || err.message).slice(0, 300))) : resolve(out.trim())))
    p.stdin.end(prompt)
  })
}

const ROLE = () => `O que é de ${nome()}: ${papel()}
O resto é de outras pessoas ou áreas.`

const STOP = new Set(['de', 'da', 'do', 'das', 'dos', 'na', 'no', 'nas', 'nos', 'a', 'o', 'e', 'em', 'pra', 'para', 'com', 'se', 'que', 'um', 'uma'])
const toks = (t) => new Set(String(t).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().split(/\W+/).filter((w) => w.length > 2 && !STOP.has(w)).map((w) => w.slice(0, 5)))
function similar (a, b) { const A = toks(a), B = toks(b); if (!A.size || !B.size) return 0; let n = 0; for (const w of A) if (B.has(w)) n++; return n / Math.min(A.size, B.size) }

const idFor = (jid, title) => createHash('sha1').update(jid + '|' + title.toLowerCase().replace(/\W+/g, ' ').trim()).digest('hex').slice(0, 12)

// fotos de referência: as que a IA apontou + a própria mensagem do pedido + fotos da mesma pessoa até 5 min antes/depois
const isImg = (m) => m && (m.type === 'imageMessage')
function refImages (msgs, idx, src) {
  const out = []
  for (const i of Array.isArray(idx) ? idx : []) { const m = msgs[Number(i)]; if (isImg(m)) out.push(m) }
  if (src && !src.from_me) {
    if (isImg(src)) out.push(src)
    for (const m of msgs) if (isImg(m) && !m.from_me && m.sender_jid === src.sender_jid && Math.abs(m.ts - src.ts) <= 300) out.push(m)
  }
  return [...new Set(out.map((m) => m.id))].slice(0, 8)
}
const mergeImgs = (a, b) => [...new Set([...(a || []), ...(b || [])])].slice(0, 8)

// demandas antigas: acha a mensagem de origem pelo horário (dá msgId pro anti-repetição e as fotos)
for (const d of Object.values(st.demands)) {
  if (d.msgId !== undefined || !d.jid) continue
  const near = db.prepare(`SELECT * FROM messages WHERE chat_jid = ? AND ts BETWEEN ? AND ? ORDER BY ts`).all(d.jid, d.ts - 300, d.ts + 300)
  const src = near.find((m) => m.ts === d.ts && !m.from_me) || null
  d.msgId = src?.id || null
  d.imgs = refImages(near, [], src)
}
// passou pra alguém: não volta pra mim na releitura
for (const d of Object.values(st.demands)) if (d.owner) { d.mine = d.owner === 'eu'; d.area = OWNER_AREA[d.owner] || 'outro' }
save()

// equipe: quando alguém dela já respondeu, não é mais comigo

const ESTADOS = ['respondida', 'esperando_cliente']
function estadoDe (j) {
  const e = ESTADOS.includes(j.estado) ? j.estado : null
  return { state: e, stateBy: e ? (String(j.estado_por || '').trim().split(' ')[0] || null) : null,
    stateNote: e === 'esperando_cliente' ? (String(j.estado_motivo || '').trim() || null) : null }
}

async function scanChat (jid, lastTs) {
  const info = chatInfo(jid)
  if (!info) return
  const isGroup = !!info.is_group
  const msgs = recent(jid)
  if (!msgs.length) { st.scanned[jid] = lastTs; return }
  await transcribeAudios(msgs)
  // já lidas numa rodada anterior: servem de contexto, mas não geram demanda nova
  const prevScan = st.scanned[jid] || 0
  const firstNew = prevScan ? msgs.findIndex((m) => m.ts > prevScan) : 0
  const lines = msgs.map((m, i) => (i === firstNew && firstNew > 0 ? '--- mensagens NOVAS desde a última leitura ---\n' : '') +
    `[${i}] ${fmtDate(m.ts)} ${m.from_me ? nome() : (isGroup ? contactName(m.sender_jid, m.push_name) : cleanName(info.name))}: ${msgText(m)}`).join('\n')
  const open = Object.values(st.demands).filter((d) => d.jid === jid && d.status === 'open')
  const closed = Object.values(st.demands).filter((d) => d.jid === jid && d.status !== 'open' && (d.doneAt || d.createdAt || 0) > now() - 30 * 86400).slice(-40)
  const ign = st.ignored.slice(-12).map((x) => `- "${x}"`).join('\n')

  const prompt = `Tu é o assistente de ${nome()}. Quer uma caixa de DEMANDAS DE TRABALHO tiradas do WhatsApp.
Agora é ${fmtDate(now())}.

Conversa ${isGroup ? `no grupo "${cleanName(info.name)}"` : `direta com "${cleanName(info.name)}"`}:
${lines}

Demandas já anotadas dessa conversa (mantenha o mesmo título e id se for a mesma coisa):
${open.length ? open.map((d) => `- id ${d.id}: ${d.title}`).join('\n') : '(nenhuma)'}
${closed.length ? `\nDemandas que o ${nome()} JÁ FEZ ou descartou nessa conversa. NÃO devolva de novo. Só inclua se tiver um pedido NOVO depois (aí devolva o mesmo id):\n${closed.map((d) => `- id ${d.id}: ${d.title}`).join('\n')}\n` : ''}
${ign ? `O ${nome()} marcou como "não é demanda" coisas assim, não repita esse tipo:\n${ign}\n` : ''}
Regras:
- Demanda = pedido de TRABALHO pra ${nome()} ou pra equipe (ajuste, entrega, relatório, acesso, orçamento, dúvida que exige ação).
- NÃO é demanda: agradecimento, ok, figurinha, papo pessoal, conversa entre outras pessoas do grupo que não pede nada pra ele, aviso sem ação, coisa que o próprio ${nome()} pediu pros outros.
- Junte várias mensagens sobre a mesma coisa numa demanda só.
- "feita": true só se a conversa mostra que o ${nome()} JÁ entregou (ex: "subi", "pronto, tá no ar", cliente confirmou).
- Título curto e claro, começando com verbo, até 7 palavras (ex: "Trocar banner da Black na home").
- "cliente": nome curto da MARCA/loja. Use exatamente um destes se for o mesmo: ${[...new Set(Object.values(st.clients))].join(', ')}. Em conversa direta, descubra a marca pelo assunto (ex: pessoa da Loja Aurora falando da loja = "Loja Aurora"); só use o nome da pessoa se não tiver marca nenhuma.
- "prazo": data AAAA-MM-DD se a mensagem disser (hoje, amanhã, sexta, até dia X), senão null. "urgente": true se pedirem urgência.
- "msg": índice [n] da mensagem onde o pedido foi feito (se pediram de novo, a mais recente).
${firstNew > 0 ? '- Mensagens ANTES da linha "mensagens NOVAS" já foram lidas: use só como contexto ou pra atualizar demanda existente. Demanda NOVA só sai de mensagem depois da linha.\n' : ''}- "imgs": índices [n] das mensagens [foto]/[fotos] que são referência visual dessa demanda (print, foto do que mudar, layout de exemplo). [] se nenhuma.
- "pra_mim": true se é trabalho de ${nome()}, false se é de outra área. "area": "dev", "trafego", "comercial", "design", "operacao" ou "outro".
- "estado": "aberta" (ainda depende da gente), "respondida" (${equipeTxt()} ou o próprio ${nome()} já respondeu ou resolveu isso na conversa e não sobrou nada pro ${nome()} fazer) ou "esperando_cliente" (a equipe pediu algo pro cliente, tipo e-mail, login, acesso, arquivo, aprovação ou lista, e ainda não chegou; sem isso não dá pra seguir). Na dúvida, "aberta". Se o cliente mandou o que faltava, volta a ser "aberta".
- "estado_por": em "respondida", primeiro nome de quem respondeu; em "esperando_cliente", primeiro nome de quem vai mandar. Senão null.
- "estado_motivo": em "esperando_cliente", até 8 palavras do que falta (ex: "e-mails das afiliadas", "login da Nuvemshop"). Senão null.
- "pedido_novo": true só se for uma demanda que já estava na lista de FEITAS e o cliente pediu de novo ou pediu algo novo sobre ela DEPOIS (mensagem nova dele). Comentário, agradecimento ou elogio sobre o que já foi entregue NÃO é pedido novo.
${ROLE()}

Responda SÓ JSON válido, sem markdown:
{"demandas":[{"id":"id existente ou null","titulo":"","detalhe":"1 frase com o que precisa ser feito","cliente":"","quem":"primeiro nome de quem pediu","msg":0,"prazo":null,"urgente":false,"feita":false,"pra_mim":true,"area":"dev","imgs":[],"estado":"aberta","estado_por":null,"estado_motivo":null,"pedido_novo":false}]}
Sem demandas: {"demandas":[]}`

  const out = await askClaude(prompt)
  const json = JSON.parse(out.slice(out.indexOf('{'), out.lastIndexOf('}') + 1))
  for (const d of json.demandas || []) {
    const title = String(d.titulo || '').trim()
    if (!title) continue
    const src = msgs[Math.max(0, Math.min(msgs.length - 1, Number(d.msg) || 0))]
    let id = d.id && st.demands[d.id]?.jid === jid ? d.id : idFor(jid, title)
    // rede de segurança: mesma coisa com título reescrito → reaproveita a demanda fechada
    if (!st.demands[id]) {
      const twin = closed.find((c) => (src?.id && c.msgId === src.id) || (src?.ts && c.ts === src.ts) || similar(c.title, title) >= 0.6) ||
        open.find((c) => (src?.id && c.msgId === src.id) || similar(c.title, title) >= 0.7)
      if (twin) id = twin.id
    }
    const prev = st.demands[id]
    // demanda nova vinda de mensagem que já tinha sido lida antes = releitura, pula
    if (!prev && prevScan && src?.ts && src.ts <= prevScan) { decide('pulei-releitura', { id, jid, msgId: src.id, client: d.cliente, title }); continue }
    if (prev && prev.status === 'ignored') continue
    // já feita: só reabre se o pedido citado é posterior a quando foi marcada feita
    if (prev && prev.status === 'done') {
      // antes: qualquer msg citada depois do "feito" reabria (até "ficou ótimo" ou conversa seguindo no grupo). Agora só pedido novo
      // de verdade: a IA marca pedido_novo, a msg é de outra pessoa, é posterior ao feito e está na parte NOVA da conversa.
      const novo = d.pedido_novo === true && src?.ts && prev.doneAt && src.ts > prev.doneAt && !src.from_me && (!prevScan || src.ts > prevScan)
      if (!novo) { if (src?.ts > (prev.doneAt || 0)) decide('manteve-feita', prev, { msgTs: src.ts }); continue }
      decide('reabriu-pedido-novo', prev, { msgTs: src.ts })
    }
    const base = {
      id, jid, title,
      detail: String(d.detalhe || '').trim(),
      client: canonClient(String(d.cliente || cleanName(info.name)).trim()),
      who: String(d.quem || '').trim(),
      chatName: cleanName(info.name),
      isGroup,
      ts: prev?.ts || src?.ts || lastTs,
      quote: msgText(src || {}).slice(0, 280),
      msgId: prev?.msgId || src?.id || null,
      imgs: mergeImgs(prev?.imgs, refImages(msgs, d.imgs, src)),
      due: d.prazo || null,
      urgent: !!d.urgente,
      // passou pra alguém: o dono manda, a IA não devolve pra mim
      mine: prev?.owner ? prev.owner === 'eu' : d.pra_mim !== false,
      area: prev?.owner ? (OWNER_AREA[prev.owner] || 'outro') : String(d.area || (d.pra_mim === false ? 'outro' : 'dev')),
      // respondida / esperando_cliente (dá pra tirar na mão: prev.stateManual)
      ...(prev?.stateManual ? {} : estadoDe(d)), stateV: 1,
    }
    if (!prev) {
      st.demands[id] = { ...base, status: d.feita ? 'done' : 'open', autoDone: !!d.feita, createdAt: now(), doneAt: d.feita ? now() : null, notified: !st.booted || !!d.feita }
    } else {
      Object.assign(prev, base)
      if (d.feita && prev.status === 'open') { prev.status = 'done'; prev.autoDone = true; prev.doneAt = now() }
    }
  }
  st.scanned[jid] = lastTs
  save()
}

async function classifyOld () {
  const todo = Object.values(st.demands).filter((d) => d.mine === undefined && d.status !== 'ignored')
  if (!todo.length) return
  const out = await askClaude(`${ROLE()}

Classifique cada demanda. Responda SÓ JSON: {"r":[{"id":"","pra_mim":true,"area":"dev|trafego|comercial|design|operacao|outro"}]}

${todo.map((d) => `- id ${d.id} · ${d.client} · ${d.who}: ${d.title}. ${d.detail}`).join('\n')}`)
  const json = JSON.parse(out.slice(out.indexOf('{'), out.lastIndexOf('}') + 1))
  for (const r of json.r || []) {
    const d = st.demands[r.id]
    if (d) { d.mine = r.pra_mim !== false; d.area = r.area || (d.mine ? 'dev' : 'outro') }
  }
  for (const d of todo) if (d.mine === undefined) d.mine = true
  save()
  log('classifiquei', todo.length, 'demandas antigas')
}

// revisão única do estado (respondida / esperando cliente) das demandas que já estavam abertas antes dessa função existir.
// Só classifica as demandas existentes, nunca cria demanda nova.
async function revisarEstados () {
  const pend = Object.values(st.demands).filter((d) => d.status === 'open' && d.mine !== false && !d.stateV && !d.stateManual)
  const porChat = {}
  for (const d of pend) (porChat[d.jid] ??= []).push(d)
  for (const [jid, ds] of Object.entries(porChat)) {
    const info = chatInfo(jid)
    if (!info) { ds.forEach((d) => { d.stateV = 1 }); continue }
    const isGroup = !!info.is_group
    const msgs = recent(jid)
    await transcribeAudios(msgs)
    const lines = msgs.map((m) => `${fmtDate(m.ts)} ${m.from_me ? nome() : (isGroup ? contactName(m.sender_jid, m.push_name) : cleanName(info.name))}: ${msgText(m)}`).join('\n')
    try {
      const out = await askClaude(`Agora é ${fmtDate(now())}. Conversa ${isGroup ? `no grupo "${cleanName(info.name)}"` : `com "${cleanName(info.name)}"`}:
${lines}

Demandas de trabalho de ${nome()} abertas nessa conversa:
${ds.map((d) => `- id ${d.id}: ${d.title}. ${d.detail || ''}`).join('\n')}

Pra cada uma, diga o estado:
- "aberta": ainda depende da gente.
- "respondida": ${equipeTxt()} ou o próprio ${nome()} já respondeu ou resolveu na conversa e não sobrou nada pro ${nome()} fazer.
- "esperando_cliente": a equipe pediu algo pro cliente (e-mail, login, acesso, arquivo, aprovação, lista) e ainda não chegou.
Na dúvida, "aberta". "estado_por": quem respondeu (respondida) ou quem vai mandar (esperando), primeiro nome, senão null. "estado_motivo": em esperando_cliente, até 8 palavras do que falta, senão null.
Responda SÓ JSON: {"r":[{"id":"","estado":"aberta","estado_por":null,"estado_motivo":null}]}`, 'haiku')
      const j = JSON.parse(out.slice(out.indexOf('{'), out.lastIndexOf('}') + 1))
      for (const r of j.r || []) { const d = st.demands[r.id]; if (d && d.jid === jid && !d.stateManual) Object.assign(d, estadoDe(r)) }
    } catch (e) { log('revisar estados', jid, e.message) }
    ds.forEach((d) => { d.stateV = 1 })
    save()
  }
}

// ===== "Fazendo": quem pegou a demanda. claude = cliquei em Claude Code; eu = eu disse no WhatsApp que tô vendo.
// Nunca fecha sozinho: "parece pronto" (doneHint) só sugere, eu confirmo.
const FAZENDO_RE = /\b(vou ver|vou verificar|vou conferir|vou olhar|vou ajustar|vou subir|vou fazer|j[aá] (te )?(confiro|vejo|olho|verifico|ajusto|subo|fa[cç]o)|verificando|conferindo|olhando|ajustando|subindo|fazendo|vamos verificar|vamos ver|vou checar|checando|vou confirmar|confirmando|estamos subindo|t[oô] vendo|to vendo|deixa eu ver|j[aá] vejo|vejo aqui|confiro aqui)\b/i
const PRONTO_RE = /\b(pronto|prontinho|subi|subiu|subid[oa]s?|corrigid[oa]s?|corrigi|ajustad[oa]s?|ajustei|feito|resolvid[oa]s?|resolvi|t[aá] no ar|no ar|publicad[oa]s?|publiquei|atualizad[oa]s?|atualizei|conclu[ií]d[oa]s?|finalizei|entregue)\b/i
function detectarFazendo () {
  let mudou = false
  for (const d of Object.values(st.demands)) {
    if (d.status !== 'open' || d.mine === false) continue
    const mine = db.prepare(`SELECT text, ts FROM messages WHERE chat_jid = ? AND from_me = 1 AND ts > ? AND type IN ('conversation','extendedTextMessage')
      ORDER BY ts`).all(d.jid, (d.ts || 0) - 60)
    let fazendo = null, pronto = null
    for (const m of mine) {
      const t = String(m.text || '')
      // "vou confirmar se já subiu", "estamos subindo", pergunta = ainda fazendo, não pronto
      const futuro = /\bvou\b|\bse j[aá]\b|\?|\bestamos\b|\bestou\b|\bt[oô]\b|\bainda\b|\bfalta\b|\bassim que\b/i.test(t)
      if (PRONTO_RE.test(t) && !futuro) pronto = m
      else if (FAZENDO_RE.test(t)) fazendo = m
    }
    if (fazendo && !d.doingManual && !d.doing && !d.doingAt) { d.doing = 'eu'; d.doingAt = fazendo.ts; d.doingQuote = String(fazendo.text).slice(0, 120); mudou = true }
    // regra mudou ou a msg não vale mais: some a sugestão antiga
    if (!pronto && d.doneHint === 'eu') { d.doneHint = null; d.doneHintQuote = null; mudou = true }
    if (pronto && pronto.ts > (d.doingAt || d.ts || 0) && d.doneHint !== 'eu' && !(d.hintDismissed >= pronto.ts)) {
      d.doneHint = 'eu'; d.doneHintAt = pronto.ts; d.doneHintQuote = String(pronto.text).slice(0, 120); mudou = true
    }
  }
  if (mudou) save()
}
// sessão do Claude: acha o transcript (~/.claude/projects/*/*.jsonl) criado depois do clique que cita a demanda;
// parado há 4 min = terminou → sugere "feito?"
const CLAUDE_PROJ = path.join(os.homedir(), '.claude/projects')
function claudeTerminou (d) {
  const desde = (d.doingAt || 0) * 1000
  const chave = [d.title, d.quote].filter(Boolean).map((x) => String(x).slice(0, 40))
  let achou = null
  try {
    for (const proj of readdirSync(CLAUDE_PROJ)) {
      const dir = path.join(CLAUDE_PROJ, proj)
      let files = []
      try { files = readdirSync(dir).filter((f) => f.endsWith('.jsonl')) } catch { continue }
      for (const f of files) {
        const fp = path.join(dir, f)
        let stt; try { stt = statSync(fp) } catch { continue }
        if (stt.mtimeMs < desde) continue
        // sessão nova: o prompt tá no começo; sessão que já existia (colei o prompt nela): olha o fim
        const len = Math.min(stt.size, 400e3)
        const pos = stt.birthtimeMs < desde - 120e3 ? stt.size - len : 0
        const fd = openSync(fp, 'r'); const buf = Buffer.alloc(len); readSync(fd, buf, 0, len, pos); closeSync(fd)
        const txt = buf.toString('utf8')
        if (chave.some((k) => k.length > 8 && txt.includes(k))) { if (!achou || stt.mtimeMs > achou.mtimeMs) achou = { fp, mtimeMs: stt.mtimeMs } }
      }
    }
  } catch {}
  if (!achou) return { sessao: false }
  return { sessao: true, parado: Date.now() - achou.mtimeMs > 4 * 60e3, fim: Math.floor(achou.mtimeMs / 1000) }
}
function checarClaude () {
  let mudou = false
  for (const d of Object.values(st.demands)) {
    if (d.status !== 'open' || d.doing !== 'claude' || d.doneHint) continue
    const r = claudeTerminou(d)
    if (r.sessao && !d.claudeSession) { d.claudeSession = true; mudou = true }
    if (r.parado) { d.doneHint = 'claude'; d.doneHintAt = r.fim; mudou = true }
  }
  if (mudou) save()
}
setInterval(() => { try { detectarFazendo(); checarClaude() } catch (e) { log('fazendo', e.message) } }, 30e3)
setTimeout(() => { try { detectarFazendo(); checarClaude() } catch (e) { log('fazendo', e.message) } }, 4000)

// fila: uma conversa por vez
let scanning = 0
let working = false
async function pump () {
  if (working) return
  working = true
  try {
    try { await classifyOld() } catch (e) { log('classificar falhou', e.message) }
    try { await revisarEstados() } catch (e) { log('revisar estados falhou', e.message) }
    for (;;) {
      const todo = activeChats().filter((c) => (st.scanned[c.jid] || 0) < c.lastTs)
      scanning = todo.length
      if (!todo.length) break
      const c = todo[0]
      try { await scanChat(c.jid, c.lastTs) } catch (e) { log('scan falhou', c.jid, e.message); st.scanned[c.jid] = c.lastTs; save() }
    }
    if (!st.booted) { st.booted = true; for (const d of Object.values(st.demands)) d.notified = true; save() }
  } finally { working = false; scanning = 0 }
}
setInterval(pump, 15e3)
setTimeout(pump, 500)

// ===== Marcações: quando te marcam (@) ou respondem tua mensagem num grupo, a "gestora" lê por ti
// e deixa 1 linha calma. Silencioso: só conta no ícone, nunca pula na tela.
st.mentions ??= {}
const MENTION_MODEL = process.env.ZAP_MENTION_MODEL || 'haiku'
const MY_JIDS = new Set(MY_IDS.flatMap((id) => [id + '@s.whatsapp.net', id + '@lid']))
function ctxInfo (o, depth = 0) {
  if (!o || typeof o !== 'object' || depth > 5) return null
  if (o.contextInfo) return o.contextInfo
  for (const v of Object.values(o)) { const c = ctxInfo(v, depth + 1); if (c) return c }
  return null
}
function clientForChat (jid, name) {
  const d = Object.values(st.demands).find((x) => x.jid === jid && x.client)
  if (d) return d.client
  const k = normKey(name)
  const hit = KNOWN.find((n) => k.includes(normKey(n)))
  return hit || cleanName(name)
}
function newMentions () {
  const since = now() - WINDOW_H * 3600
  const like = MY_IDS.map(() => 'm.raw LIKE ?').join(' OR ')
  const rows = db.prepare(`SELECT * FROM messages m WHERE m.from_me = 0 AND m.chat_jid LIKE '%@g.us' AND m.ts > ?
    AND m.type IN ${REAL} AND (${like}) ORDER BY m.ts`).all(since, ...MY_IDS.map((id) => `%${id}%`))
  const out = []
  for (const m of rows) {
    if (st.mentions[m.id] || st.muted[m.chat_jid]) continue
    let c = null
    try { c = ctxInfo(JSON.parse(m.raw).message) } catch {}
    if (!c) continue
    const tagged = (c.mentionedJid || []).some((j) => MY_JIDS.has(j))
    const replied = !tagged && c.quotedMessage && MY_JIDS.has(c.participant)
    if (tagged || replied) out.push({ m, how: tagged ? 'marcou' : 'respondeu' })
  }
  return out
}
async function scanMentions () {
  const fresh = newMentions()
  if (!fresh.length) return
  const byChat = {}
  for (const x of fresh) (byChat[x.m.chat_jid] ??= []).push(x)
  for (const [jid, list] of Object.entries(byChat)) {
    const info = chatInfo(jid)
    const name = cleanName(info?.name || jid)
    const first = list[0].m.ts, last = list[list.length - 1].m.ts
    const ctx = db.prepare(`SELECT * FROM messages WHERE chat_jid = ? AND type IN ${REAL} AND ts BETWEEN ? AND ? ORDER BY ts`).all(jid, first - 6 * 3600, last + 1800)
      .slice(-60)
    await transcribeAudios(ctx)
    const idx = new Map(ctx.map((m, i) => [m.id, i]))
    const lines = ctx.map((m, i) => `[${i}] ${fmtDate(m.ts)} ${m.from_me ? nome() : contactName(m.sender_jid, m.push_name)}: ${msgText(m)}`).join('\n')
    const targets = list.filter((x) => idx.has(x.m.id))
    let res = []
    try {
      const out = await askClaude(`Tu é a assistente de ${nome()}. Não quer ler as conversas inteiras dos grupos: tu lê por ele e resume.
Agora é ${fmtDate(now())}. Grupo "${name}":
${lines}

Marcaram ou responderam o ${nome()} nas mensagens: ${targets.map((x) => `[${idx.get(x.m.id)}]`).join(', ')}.
Pra cada uma, devolva:
- "resumo": 1 linha calma e objetiva do que querem DELE, até 12 palavras. Se for pedido, comece com verbo ("Atualizar banners de categoria da Black"). Tom neutro: transforme cobrança ou reclamação em pedido simples, sem drama, sem repetir grosseria. Se ele já respondeu/resolveu depois na conversa, diga isso ("Já respondeste, ela confirmou").
- "tipo": "fazer" (pede trabalho ou ajuste), "responder" (pergunta ou decisão que só ele responde, sem trabalho grande), "aviso" (só informou, agradeceu, marcou pra ciência, nada a fazer), "resolvido" (o ${nome()} já respondeu ou entregou depois), "respondida" (${equipeTxt()} já respondeu por ele depois) ou "esperando" (já pedimos algo pro cliente, tipo e-mail ou login, e falta ele mandar).
- "por": em "respondida", primeiro nome de quem respondeu; em "esperando", até 8 palavras do que falta. Senão null.
- "urgente": true só se pedirem urgência de verdade (hoje, agora, loja fora do ar).
Responda SÓ JSON: {"m":[{"i":0,"resumo":"","tipo":"fazer","urgente":false,"por":null}]}`, MENTION_MODEL)
      res = JSON.parse(out.slice(out.indexOf('{'), out.lastIndexOf('}') + 1)).m || []
    } catch (e) { log('marcações falhou', name, e.message) }
    const byIdx = new Map(res.map((r) => [Number(r.i), r]))
    for (const { m, how } of list) {
      const r = byIdx.get(idx.get(m.id)) || {}
      const tipo = ['fazer', 'responder', 'aviso', 'resolvido', 'respondida', 'esperando'].includes(r.tipo) ? r.tipo : 'responder'
      const por = r.por ? String(r.por).trim() : null
      const dem = Object.values(st.demands).find((d) => d.msgId === m.id || (d.jid === jid && Math.abs((d.ts || 0) - m.ts) < 120))
      st.mentions[m.id] = {
        id: m.id, jid, ts: m.ts, how, chatName: name, client: clientForChat(jid, name),
        who: contactName(m.sender_jid, m.push_name).split(' ')[0],
        quote: msgText(m).slice(0, 400),
        summary: String(r.resumo || '').trim() || msgText(m).slice(0, 90),
        kind: tipo, urgent: !!r.urgente, demandId: dem?.id || null,
        espera: tipo === 'respondida' ? 'respondida' : (tipo === 'esperando' ? 'esperando_cliente' : null),
        esperaPor: tipo === 'respondida' ? (por || '').split(' ')[0] || null : null, esperaNota: tipo === 'esperando' ? por : null,
        // primeira leitura (app acabou de ganhar a aba): não acende contador com coisa velha
        seen: !st.mentionsBooted || tipo === 'resolvido', ok: tipo === 'resolvido', at: now(),
      }
    }
    save()
  }
}
function mentionList () {
  const cut = now() - WINDOW_H * 3600
  for (const [k, x] of Object.entries(st.mentions)) if (x.ts < now() - 7 * 86400) delete st.mentions[k]
  const items = Object.values(st.mentions).filter((x) => x.ts > cut).sort((a, b) => b.ts - a.ts)
    .map((x) => ({ id: x.id, jid: x.jid, ts: x.ts, how: x.how, chatName: x.chatName, client: x.client, who: x.who, quote: x.quote,
      summary: x.summary, kind: x.kind, urgent: x.urgent, seen: !!x.seen, ok: !!x.ok,
      espera: x.espera || null, esperaPor: x.esperaPor || null, esperaNota: x.esperaNota || null,
      demandId: x.demandId && st.demands[x.demandId]?.status === 'open' ? x.demandId : null }))
  return { unseen: items.filter((x) => !x.seen && !x.ok && !x.espera).length, items }
}
let mentionWorking = false
async function mentionPump () {
  if (mentionWorking) return
  mentionWorking = true
  try { await scanMentions(); if (!st.mentionsBooted) { st.mentionsBooted = true; save() } } catch (e) { log('marcações', e.message) } finally { mentionWorking = false }
}
setInterval(mentionPump, 20e3)
setTimeout(mentionPump, 3000)

// ===== Não lidas: o que chegou e eu ainda não li em nenhum aparelho. A IA resume cada conversa e,
// quando precisa de resposta minha, sugere o texto (no meu jeito). Enviar só quando eu clico.
st.unread ??= {}      // jid → { key: id da última msg resumida, summary, needsReply, urgent, suggestion, kind, at }
st.readLocal ??= {}   // jid → ts: "ok, li" aqui no Demandas (não manda azulzinho pro WhatsApp)
const UNREAD_MODEL = process.env.ZAP_UNREAD_MODEL || 'sonnet'
const hasReads = !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='reads'").get()
function unreadChats () {
  if (!hasReads) return []
  const since = now() - WINDOW_H * 3600
  return db.prepare(`
    SELECT m.chat_jid AS jid, COUNT(*) AS n, MAX(m.ts) AS lastTs, MAX(COALESCE(r.marked_unread, 0)) AS marked
    FROM messages m LEFT JOIN reads r ON r.jid = m.chat_jid
    WHERE m.from_me = 0 AND m.type IN ${REAL} AND m.ts > ?
      AND m.chat_jid NOT LIKE '%@broadcast' AND m.chat_jid NOT LIKE '%@newsletter'
      AND (r.marked_unread = 1 OR m.ts > COALESCE(r.read_ts, 0))
      AND m.ts > COALESCE((SELECT MAX(x.ts) FROM messages x WHERE x.chat_jid = m.chat_jid AND x.from_me = 1), 0)
    GROUP BY m.chat_jid ORDER BY lastTs DESC LIMIT 40`).all(since)
    .filter((c) => !st.muted[c.jid] && !(lidoEm(c.jid) >= c.lastTs))
}
// "lido" vale de qualquer lugar do app: "ok, li" aqui (readLocal) OU abrir/ler/responder a conversa no chat (servidor do Privado, state.json)
// Antes só o readLocal contava, então conversa lida pelo chat voltava pra lista de não lidas.
const PRIV_STATE = path.join(HOME, 'conversas/state.json')
let privCache = { mtime: 0, read: {} }
function privRead () {
  try {
    const m = statSync(PRIV_STATE).mtimeMs
    if (m !== privCache.mtime) privCache = { mtime: m, read: JSON.parse(readFileSync(PRIV_STATE, 'utf8')).read || {} }
  } catch {}
  return privCache.read
}
const lidoEm = (jid) => Math.max(Number(st.readLocal[jid] || 0), Number(privRead()[jid] || 0))
const lastMsgOf = (jid) => db.prepare(`SELECT id, ts FROM messages WHERE chat_jid = ? AND from_me = 0 AND type IN ${REAL} ORDER BY ts DESC LIMIT 1`).get(jid)
function myStyle () {
  return db.prepare(`SELECT text FROM messages WHERE from_me = 1 AND type IN ('conversation','extendedTextMessage') AND length(text) BETWEEN 4 AND 160
    ORDER BY ts DESC LIMIT 40`).all().map((r) => `- ${r.text.replace(/\s+/g, ' ')}`).join('\n')
}
async function summarizeChat (c, hint = '') {
  const info = chatInfo(c.jid)
  if (!info) return
  const isGroup = !!info.is_group
  const name = cleanName(info.name)
  const msgs = db.prepare(`SELECT * FROM (SELECT * FROM messages WHERE chat_jid = ? AND type IN ${REAL} ORDER BY ts DESC LIMIT 30) ORDER BY ts`).all(c.jid)
  await transcribeAudios(msgs)
  const readTs = c.marked ? 0 : (db.prepare('SELECT read_ts FROM reads WHERE jid = ?').get(c.jid)?.read_ts || 0)
  const cut = Math.max(readTs, ...msgs.filter((x) => x.from_me).map((x) => x.ts), 0)
  const firstNew = msgs.findIndex((m) => !m.from_me && m.ts > cut)
  const lines = msgs.map((m, i) => (i === firstNew ? '--- NÃO LIDAS a partir daqui ---\n' : '') +
    `${fmtDate(m.ts)} ${m.from_me ? nome() : (isGroup ? contactName(m.sender_jid, m.push_name) : name)}: ${msgText(m)}`).join('\n')
  const dem = Object.values(st.demands).filter((d) => d.jid === c.jid && d.status === 'open').map((d) => `- ${d.title}`).join('\n')
  const out = await askClaude(`Tu é o assistente de ${nome()}. Não quer abrir o WhatsApp: tu lê as mensagens não lidas por ele, resume e, se precisar, sugere a resposta.
Agora é ${fmtDate(now())}.

Conversa ${isGroup ? `no grupo "${name}"` : `direta com "${name}"`}:
${lines}
${dem ? `\nDemandas de trabalho já anotadas dessa conversa (não precisa repetir no resumo):\n${dem}\n` : ''}
Devolva:
- "resumo": NO MÁXIMO 18 palavras, do que as NÃO LIDAS dizem, tom calmo e direto (cobrança vira pedido simples). Comece por quem falou ("Celso pergunta se…"). Em grupo onde ninguém fala com o ${nome()}, só o assunto em até 12 palavras, sem dizer "ninguém pediu nada".
- "precisa_resposta": true só se alguém pergunta ou pede algo que o KEVYN deve responder agora (não conta: papo entre outros, agradecimento, ok, figurinha, aviso, coisa já respondida).
- "respondida_por": se a pergunta/pedido das não lidas JÁ foi respondido na conversa por ${equipeTxt()}, o primeiro nome de quem respondeu (aí precisa_resposta = false). Senão null.
- "esperando_cliente": true se o ponto atual é a equipe esperando o cliente mandar algo (e-mail, login, acesso, arquivo, aprovação) e o cliente ainda não mandou; aí precisa_resposta = false. Se o cliente acabou de mandar o que faltava, false.
- "falta": se esperando_cliente, até 8 palavras do que falta (ex: "e-mails das afiliadas"). Senão null.
- "urgente": true só com urgência real (hoje, agora, loja fora do ar, cliente bravo).
- "tipo": "pergunta", "pedido", "aviso" ou "papo".
- "sugestao": se precisa_resposta, a mensagem que o ${nome()} pode mandar, senão null. Escreva do jeito que essa pessoa escreve (veja os exemplos abaixo): mesmo tom, mesmo tamanho, mesmas gírias e pontuação.
  Curta (1 a 2 frases), sem saudação se a conversa já está rolando hoje, sem lista. Não prometa prazo que ele não deu; se não souber a resposta técnica, sugira algo como "vou ver isso e já te falo". Não invente fatos.
${hint ? `- O ${nome()} pediu pra sugestão: ${hint}\n` : ''}
Exemplos de mensagens que o ${nome()} mandou (imite o tom):
${myStyle()}

Responda SÓ JSON: {"resumo":"","precisa_resposta":false,"urgente":false,"tipo":"papo","sugestao":null,"respondida_por":null,"esperando_cliente":false,"falta":null}`, UNREAD_MODEL)
  const j = JSON.parse(out.slice(out.indexOf('{'), out.lastIndexOf('}') + 1))
  const last = lastMsgOf(c.jid)
  const porQuem = String(j.respondida_por || '').trim().split(' ')[0] || null
  const espera = porQuem ? 'respondida' : (j.esperando_cliente ? 'esperando_cliente' : null)
  if (espera) j.precisa_resposta = false
  st.unread[c.jid] = {
    key: last?.id || null,
    espera, esperaPor: porQuem, esperaNota: espera === 'esperando_cliente' ? (String(j.falta || '').trim() || null) : null,
    summary: String(j.resumo || '').trim(),
    needsReply: !!j.precisa_resposta,
    urgent: !!j.urgente,
    kind: ['pergunta', 'pedido', 'aviso', 'papo'].includes(j.tipo) ? j.tipo : 'papo',
    suggestion: j.precisa_resposta && j.sugestao ? String(j.sugestao).replace(/\s[—–]\s/g, ', ').trim() : null,
    at: now(),
  }
  save()
}
let unreadWorking = false
let unreadBusy = 0
async function unreadPump () {
  if (unreadWorking) return
  unreadWorking = true
  try {
    for (;;) {
      // espera 15 s de silêncio na conversa (quem manda 5 mensagens seguidas vira 1 resumo só)
      const todo = unreadChats().filter((c) => st.unread[c.jid]?.key !== lastMsgOf(c.jid)?.id && now() - c.lastTs > 15)
      unreadBusy = todo.length
      if (!todo.length) break
      const c = todo[0]
      try { await summarizeChat(c) } catch (e) {
        log('não lidas falhou', c.jid, e.message)
        st.unread[c.jid] = { key: lastMsgOf(c.jid)?.id, summary: '', needsReply: false, urgent: false, kind: 'papo', suggestion: null, at: now(), failed: true }
      }
    }
    // limpa resumo de conversa que já foi lida
    const live = new Set(unreadChats().map((c) => c.jid))
    for (const jid of Object.keys(st.unread)) if (!live.has(jid) && now() - (st.unread[jid].at || 0) > 3600) delete st.unread[jid]
    for (const [jid, t] of Object.entries(st.readLocal)) if (t < now() - 7 * 86400) delete st.readLocal[jid]
  } finally { unreadWorking = false; unreadBusy = 0 }
}
setInterval(unreadPump, 10e3)
setTimeout(unreadPump, 2000)

function unreadView () {
  const items = unreadChats().map((c) => {
    const info = chatInfo(c.jid) || {}
    const isGroup = !!info.is_group
    const name = cleanName(info.name || c.jid)
    const u = st.unread[c.jid]
    const fresh = u && u.key === lastMsgOf(c.jid)?.id
    const tail = db.prepare(`SELECT * FROM (SELECT * FROM messages WHERE chat_jid = ? AND type IN ${REAL} ORDER BY ts DESC LIMIT ?) ORDER BY ts`).all(c.jid, Math.min(8, c.n + 1))
    return {
      jid: c.jid, name, isGroup, client: clientForChat(c.jid, name), count: c.n, lastTs: c.lastTs,
      summary: u?.summary || '', needsReply: !!u?.needsReply, urgent: !!u?.urgent, kind: u?.kind || 'papo',
      suggestion: u?.suggestion || null, pending: !fresh, failed: !!u?.failed,
      espera: u?.espera || null, esperaPor: u?.esperaPor || null, esperaNota: u?.esperaNota || null,
      demands: Object.values(st.demands).filter((d) => d.jid === c.jid && d.status === 'open' && d.mine !== false).length,
      tail: tail.map((m) => ({ me: !!m.from_me, who: m.from_me ? 'tu' : (isGroup ? contactName(m.sender_jid, m.push_name).split(' ')[0] : name.split(' ')[0]), text: msgText(m).slice(0, 300), ts: m.ts })),
    }
  })
  return { busy: unreadBusy, needReply: items.filter((x) => x.needsReply).length, items }
}
async function sendReply (jid, text) {
  const token = readFileSync(TOKEN_PATH, 'utf8').trim()
  const r = await fetch(`${BRIDGE}/send`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ jid, text }), signal: AbortSignal.timeout(20000) })
  const j = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(j.error || `ponte respondeu ${r.status}`)
  return j
}

// fotos (via ponte, cache em disco por 2 dias)
const avatarPending = new Map()
async function avatarFile (jid) {
  const f = path.join(AVATARS, createHash('sha1').update(jid).digest('hex') + '.jpg')
  const miss = f + '.none'
  const fresh = (p) => existsSync(p) && Date.now() - statSync(p).mtimeMs < 2 * 86400e3
  if (fresh(f)) return f
  if (fresh(miss)) return null
  if (avatarPending.has(jid)) return avatarPending.get(jid)
  const job = (async () => {
    try {
      const token = readFileSync(TOKEN_PATH, 'utf8').trim()
      const r = await fetch(`${BRIDGE}/avatar?jid=${encodeURIComponent(jid)}`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(8000) })
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

// arquivo da foto: a ponte já baixa as imagens sozinha (media_path); se não tiver, pede pra ela baixar
async function imgFile (jid, msgId) {
  const row = db.prepare('SELECT media_path FROM messages WHERE chat_jid = ? AND id = ?').get(jid, msgId)
  if (row?.media_path && existsSync(row.media_path)) return row.media_path
  try {
    const token = readFileSync(TOKEN_PATH, 'utf8').trim()
    const r = await fetch(`${BRIDGE}/media`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify({ chat: jid, id: msgId }), signal: AbortSignal.timeout(20000) })
    const j = await r.json()
    return j.path && existsSync(j.path) ? j.path : null
  } catch { return null }
}
async function imgPaths (d) {
  const out = []
  for (const id of d.imgs || []) { const f = await imgFile(d.jid, id); if (f) out.push(f) }
  return out
}

async function bridgeOk () {
  try {
    const token = readFileSync(TOKEN_PATH, 'utf8').trim()
    const r = await fetch(`${BRIDGE}/status`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(1500) })
    return (await r.json()).connected === true
  } catch { return false }
}

function view (d) {
  return { id: d.id, jid: d.jid, title: d.title, detail: d.detail, client: d.client, who: d.who, chatName: d.chatName,
    isGroup: d.isGroup, ts: d.ts, quote: d.quote, due: d.due, urgent: d.urgent, status: d.status, autoDone: !!d.autoDone,
    mine: d.mine !== false, area: d.area || 'dev',
    doneAt: d.doneAt, isNew: !d.notified, imgs: (d.imgs || []).length,
    espera: d.state || null, esperaPor: d.stateBy || null, esperaNota: d.stateNote || null,
    msgId: d.msgId || null, doing: d.doing || null, doingAt: d.doingAt || null, doneHint: d.doneHint || null, doneHintQuote: d.doneHintQuote || null }
}

function promptFor (d, imgs = []) {
  return `Demanda do ${d.client} pelo WhatsApp (${d.who || 'cliente'}, ${d.isGroup ? `grupo "${d.chatName}"` : 'conversa direta'}, ${fmtDate(d.ts)}):
${d.title}. ${d.detail}

Mensagem original: "${d.quote}"
${d.due ? `Prazo: ${d.due}\n` : ''}${d.urgent ? 'Marcado como urgente.\n' : ''}${imgs.length ? `Imagens de referência que mandaram (abre e olha):\n${imgs.map((f) => `- ${f}`).join('\n')}\n` : ''}
Lê o contexto do ${d.client} na memória, me diz o plano rapidinho e faz.`
}

const prioDue = (d) => { const t = dayOf(now()); return (d.due && d.due < t ? -3 : d.due === t ? -2 : 0) + (d.urgent ? -2 : 0) }
async function promptForClient (client) {
  const list = Object.values(st.demands).filter((d) => d.status === 'open' && d.client === client && d.mine !== false)
    .sort((a, b) => (prioDue(a) - prioDue(b)) || (a.ts - b.ts))
  if (!list.length) return null
  const paths = await Promise.all(list.map(imgPaths))
  const items = list.map((d, i) => `${i + 1}. ${d.title}. ${d.detail}
   ${d.who || 'cliente'}, ${d.isGroup ? `grupo "${d.chatName}"` : 'conversa direta'}, ${fmtDate(d.ts)}${d.due ? ` · prazo ${d.due}` : ''}${d.urgent ? ' · URGENTE' : ''}
   Mensagem: "${d.quote}"${paths[i].length ? `\n   Imagens de referência: ${paths[i].join(' ')}` : ''}`).join('\n\n')
  return `Demandas do ${client} pelo WhatsApp (${list.length}):

${items}

Lê o contexto do ${client} na memória, me diz o plano rapidinho pra cada uma (na ordem que fizer mais sentido) e vai fazendo.`
}

const body = (req) => new Promise((res) => { let s = ''; req.on('data', (c) => (s += c)); req.on('end', () => { try { res(JSON.parse(s || '{}')) } catch { res({}) } }) })
const send = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)) }

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x')
    if (req.method === 'GET' && url.pathname === '/demands') {
      const all = Object.values(st.demands)
      const t = dayOf(now())
      const open = all.filter((d) => d.status === 'open').map(view)
      const doneToday = all.filter((d) => d.status === 'done' && d.doneAt && dayOf(d.doneAt) === t).sort((a, b) => b.doneAt - a.doneAt).map(view)
      return send(res, 200, { connected: await bridgeOk(), scanning, booted: st.booted, today: t, open, doneToday, mentions: mentionList(), unread: unreadView() })
    }
    if (req.method === 'GET' && url.pathname === '/mentions') return send(res, 200, mentionList())
    if (req.method === 'GET' && url.pathname === '/avatar') {
      const f = await avatarFile(url.searchParams.get('jid') || '')
      if (!f) { res.writeHead(404); return res.end() }
      res.writeHead(200, { 'content-type': 'image/jpeg', 'cache-control': 'max-age=3600' })
      return res.end(readFileSync(f))
    }
    if (req.method === 'GET' && url.pathname === '/prompt') {
      const d = st.demands[url.searchParams.get('id')]
      if (!d) return send(res, 404, { error: 'demanda não existe' })
      return send(res, 200, { text: promptFor(d, await imgPaths(d)) })
    }
    if (req.method === 'GET' && url.pathname === '/prompt-client') {
      const text = await promptForClient(url.searchParams.get('client') || '')
      if (!text) return send(res, 404, { error: 'sem demandas abertas' })
      return send(res, 200, { text })
    }
    // foto de referência n da demanda
    if (req.method === 'GET' && url.pathname === '/img') {
      const d = st.demands[url.searchParams.get('id')]
      const msgId = d?.imgs?.[Number(url.searchParams.get('n')) || 0]
      const f = msgId ? await imgFile(d.jid, msgId) : null
      if (!f) { res.writeHead(404); return res.end() }
      const ext = path.extname(f).slice(1).toLowerCase()
      res.writeHead(200, { 'content-type': ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : 'image/jpeg', 'cache-control': 'max-age=86400' })
      return res.end(readFileSync(f))
    }
    // caminho no disco (pra abrir no Preview)
    if (req.method === 'GET' && url.pathname === '/img-path') {
      const d = st.demands[url.searchParams.get('id')]
      const msgId = d?.imgs?.[Number(url.searchParams.get('n')) || 0]
      const f = msgId ? await imgFile(d.jid, msgId) : null
      return f ? send(res, 200, { path: f }) : send(res, 404, { error: 'sem foto' })
    }
    const b = req.method === 'POST' ? await body(req) : {}
    const d = b.id ? st.demands[b.id] : null
    if (req.method === 'POST' && url.pathname === '/done' && d) { d.doing = null; d.doneHint = null; d.status = 'done'; d.autoDone = false; d.doneAt = now(); decide('feito', d); save(); return send(res, 200, { ok: true }) }
    // fazendo: who = claude | eu | '' (parar). hint=0 = descarta o "parece pronto"
    if (req.method === 'POST' && url.pathname === '/doing' && (d || b.client)) {
      const alvo = d ? [d] : Object.values(st.demands).filter((x) => x.status === 'open' && x.mine !== false && x.client === b.client)
      for (const x of alvo) {
        if (b.hint === 0) { x.hintDismissed = x.doneHintAt || now(); x.doneHint = null; continue }
        const who = ['claude', 'eu'].includes(b.who) ? b.who : null
        x.doing = who; x.doingAt = who ? now() : null; x.doneHint = null; x.claudeSession = false
        x.doingManual = b.manual !== false
        decide(who ? 'fazendo-' + who : 'parou', x)
      }
      save(); return send(res, 200, { ok: true, n: alvo.length })
    }
    if (req.method === 'POST' && url.pathname === '/state' && d) {
      d.state = b.state && ESTADOS.includes(b.state) ? b.state : null; d.stateBy = null; d.stateNote = null; d.stateManual = true
      decide(d.state ? 'estado-' + d.state : 'estado-voltar', d); save(); return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/reopen' && d) { d.status = 'open'; d.doneAt = null; decide('reabrir', d); save(); return send(res, 200, { ok: true }) }
    if (req.method === 'POST' && url.pathname === '/ignore' && d) {
      d.status = 'ignored'; decide('nao-e-demanda', d); st.ignored.push(`${d.title} (${d.quote.slice(0, 80)})`); st.ignored = st.ignored.slice(-40); save()
      return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/notified') {
      for (const id of b.ids || []) if (st.demands[id]) st.demands[id].notified = true
      save(); return send(res, 200, { ok: true })
    }
    // troca de responsável (rota pra integrações externas)
    if (req.method === 'POST' && url.pathname === '/owner' && d && b.owner) {
      d.mine = b.owner === 'eu'; d.area = OWNER_AREA[b.owner] || 'outro'; d.owner = b.owner; decide('passar-pra', d, { owner: b.owner })
      save(); return send(res, 200, { ok: true })
    }
    // demanda criada à mão (rota pra integrações externas)
    if (req.method === 'POST' && url.pathname === '/add' && b.id && b.title && !st.demands[b.id]) {
      const AREA = OWNER_AREA
      st.demands[b.id] = {
        id: b.id, jid: b.jid || null, title: String(b.title), detail: String(b.detail || ''), client: canonClient(String(b.client || '')),
        who: String(b.who || ''), chatName: String(b.chatName || b.client || ''), isGroup: true, ts: Number(b.ts) || now(),
        quote: '', due: b.due || null, urgent: !!b.urgent, mine: b.owner === 'eu', area: AREA[b.owner] || 'outro', owner: b.owner,
        status: b.status === 'done' ? 'done' : 'open', autoDone: false, createdAt: now(), doneAt: b.status === 'done' ? now() : null,
        notified: false, source: 'board',
      }
      save(); return send(res, 200, { ok: true })
    }
    // Marcações: abriu a aba = viu tudo; "ok" = tira da lista; "desfazer" volta
    if (req.method === 'POST' && url.pathname === '/mentions/seen') {
      for (const x of Object.values(st.mentions)) x.seen = true
      save(); return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/mentions/ok' && st.mentions[b.id]) {
      st.mentions[b.id].ok = b.ok !== false; st.mentions[b.id].seen = true
      decide(b.ok === false ? 'marcacao-voltar' : 'marcacao-ok', { id: b.id, jid: st.mentions[b.id].jid, title: st.mentions[b.id].summary })
      save(); return send(res, 200, { ok: true })
    }
    // Não lidas: "ok, li" (só aqui), outra sugestão, enviar (só quando eu clico em enviar)
    if (req.method === 'POST' && url.pathname === '/unread/ok' && b.jid) {
      st.readLocal[b.jid] = b.ok === false ? 0 : now(); decide(b.ok === false ? 'nao-lida-voltar' : (b.motivo === 'respondido' ? 'nao-lida-respondida' : 'nao-lida-ok'), { jid: b.jid }); save()
      return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/unread/redo' && b.jid) {
      const c = unreadChats().find((x) => x.jid === b.jid)
      if (!c) return send(res, 404, { error: 'conversa já lida' })
      await summarizeChat(c, String(b.hint || 'outra opção, diferente da anterior'))
      return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/reply' && b.jid && b.text) {
      const text = String(b.text).trim()
      await sendReply(b.jid, text)
      decide('respondeu', { jid: b.jid, title: text.slice(0, 120) }, { suggested: st.unread[b.jid]?.suggestion || null })
      st.readLocal[b.jid] = now(); delete st.unread[b.jid]; save()
      return send(res, 200, { ok: true })
    }
    if (req.method === 'POST' && url.pathname === '/mute' && b.jid) {
      st.muted[b.jid] = true
      for (const x of Object.values(st.demands)) if (x.jid === b.jid && x.status === 'open') x.status = 'ignored'
      decide('silenciar-conversa', { jid: b.jid })
      save(); return send(res, 200, { ok: true })
    }
    send(res, 404, { error: 'rota' })
  } catch (e) {
    log('erro', e.message)
    send(res, 500, { error: e.message })
  }
}).on('error', (e) => { log('servidor não subiu', e.message); process.exit(1) })
  .listen(PORT, '127.0.0.1', () => log(`Demandas em http://127.0.0.1:${PORT}`))

// erro solto: sai e o app relança
process.on('uncaughtException', (e) => { log('uncaught', e?.message); process.exit(1) })
