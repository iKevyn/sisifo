// Sísifo: configuração compartilhada dos servidores locais.
// Tudo que é da pessoa (nome, o que é dela, equipe) vem de config.json, preenchido na primeira abertura do app.
import os from 'node:os'
import path from 'node:path'
import { readFileSync, statSync, mkdirSync, existsSync } from 'node:fs'

export const HOME = process.env.SISIFO_HOME || path.join(os.homedir(), 'Library/Application Support/Sisifo')
export const WA_DATA = process.env.SISIFO_WA_DATA || path.join(HOME, 'whatsapp')
export const BRIDGE_PORT = Number(process.env.SISIFO_BRIDGE_PORT || 47851)
export const APP_PORT = Number(process.env.SISIFO_PORT || 47852)
export const CHAT_PORT = Number(process.env.SISIFO_CHAT_PORT || 47853)
export const BRIDGE = `http://127.0.0.1:${BRIDGE_PORT}`
export const DB_PATH = path.join(WA_DATA, 'wa.db')
export const TOKEN_PATH = path.join(WA_DATA, 'token')
export const CONFIG_FILE = path.join(HOME, 'config.json')
mkdirSync(HOME, { recursive: true })

// claude CLI: lugares comuns de instalação
export const CLAUDE = [
  process.env.SISIFO_CLAUDE,
  path.join(os.homedir(), '.local/bin/claude'),
  path.join(os.homedir(), '.claude/local/claude'),
  '/opt/homebrew/bin/claude',
  '/usr/local/bin/claude',
].filter(Boolean).find(existsSync)

const PADRAO = {
  nome: 'Você',
  papel: 'É dela o trabalho que pedem diretamente pra ela nos grupos.',
  equipe: [],   // [{ nome, numero }] numero só dígitos com DDI, ex 5511999999999
}

let cache = { mtime: -1, cfg: PADRAO }
export function cfg () {
  try {
    const m = statSync(CONFIG_FILE).mtimeMs
    if (m !== cache.mtime) cache = { mtime: m, cfg: { ...PADRAO, ...JSON.parse(readFileSync(CONFIG_FILE, 'utf8')) } }
  } catch {}
  return cache.cfg
}
export const nome = () => cfg().nome || PADRAO.nome
export const papel = () => cfg().papel || PADRAO.papel
export const equipeNomes = () => (cfg().equipe || []).map((p) => p.nome).filter(Boolean)
export const equipeNumeros = () => (cfg().equipe || []).map((p) => String(p.numero || '').replace(/\D/g, '')).filter(Boolean)
export const equipeTxt = () => {
  const n = equipeNomes()
  return n.length ? `outra pessoa da equipe (${n.join(', ')})` : 'outra pessoa da equipe'
}

// "Marcar como lido no WhatsApp" (ajuste do app, padrão desligado): quando ligado, ler no Sísifo
// ("ok, li", abrir a conversa, responder) manda o azulzinho e tira o "não lida" do celular.
export const marcarLidoWhats = () => cfg().marcarLidoWhats === true
const ultimoLido = new Map()
export function lerNoWhats (jid) {
  if (!jid || !marcarLidoWhats()) return
  const t = Date.now()
  if (t - (ultimoLido.get(jid) || 0) < 5000) return
  ultimoLido.set(jid, t)
  let token = ''
  try { token = readFileSync(TOKEN_PATH, 'utf8').trim() } catch { return }
  fetch(`${BRIDGE}/read`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ jid }), signal: AbortSignal.timeout(15000) })
    .then((r) => r.json()).then((j) => { if (j?.error) console.log(new Date().toISOString(), 'lido no whats falhou', jid, j.error) })
    .catch((e) => console.log(new Date().toISOString(), 'lido no whats falhou', jid, e.message))
}

// "Ignorar conversas arquivadas" (ajuste do app, padrão ligado): conversa arquivada no WhatsApp
// não vira demanda, não-lida nem marcação. A ponte guarda chats.archived (vem do celular).
export const ignorarArquivadas = () => cfg().ignorarArquivadas !== false
// trecho SQL pra pôr no WHERE: `AND ${semArquivadas(db, 'm.chat_jid')}`
export function semArquivadas (db, col) {
  if (!ignorarArquivadas()) return '1=1'
  const tem = db.prepare('PRAGMA table_info(chats)').all().some((c) => c.name === 'archived')
  return tem ? `${col} NOT IN (SELECT jid FROM chats WHERE archived = 1)` : '1=1'
}
