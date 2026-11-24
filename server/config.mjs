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
