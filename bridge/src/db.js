// Banco local (SQLite embutido do Node). A ponte escreve; o MCP lê e cria rascunhos.
import { DatabaseSync } from 'node:sqlite'
import { mkdirSync, chmodSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
// Sísifo: os dados ficam fora do app (Application Support), nunca dentro do bundle
export const DATA = process.env.SISIFO_WA_DATA || path.join(ROOT, 'data')
mkdirSync(DATA, { recursive: true })
try { chmodSync(DATA, 0o700) } catch {}

export function openDb () {
  const db = new DatabaseSync(path.join(DATA, 'wa.db'))
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA busy_timeout = 5000;
    CREATE TABLE IF NOT EXISTS chats (
      jid TEXT PRIMARY KEY, name TEXT, is_group INTEGER DEFAULT 0, last_ts INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS contacts (
      jid TEXT PRIMARY KEY, name TEXT, notify TEXT
    );
    CREATE TABLE IF NOT EXISTS messages (
      chat_jid TEXT NOT NULL, id TEXT NOT NULL, sender_jid TEXT, from_me INTEGER,
      ts INTEGER, type TEXT, text TEXT, push_name TEXT,
      PRIMARY KEY (chat_jid, id)
    );
    CREATE INDEX IF NOT EXISTS idx_msg_chat_ts ON messages (chat_jid, ts);
    CREATE INDEX IF NOT EXISTS idx_msg_ts ON messages (ts);
    CREATE TABLE IF NOT EXISTS drafts (
      id INTEGER PRIMARY KEY AUTOINCREMENT, chat_jid TEXT NOT NULL, text TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pendente', created_at INTEGER, sent_at INTEGER, error TEXT
    );
    CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
    CREATE TABLE IF NOT EXISTS lid_map (lid TEXT PRIMARY KEY, pn TEXT NOT NULL);
    -- até quando eu já li cada conversa (celular, ZapFast ou outro aparelho); marked_unread = "marcar como não lida"
    CREATE TABLE IF NOT EXISTS reads (jid TEXT PRIMARY KEY, read_ts INTEGER DEFAULT 0, marked_unread INTEGER DEFAULT 0);
  `)
  // Colunas novas (mídia): raw = mensagem original p/ baixar depois; transcript = áudio transcrito.
  const cols = new Set(db.prepare('PRAGMA table_info(messages)').all().map(c => c.name))
  for (const c of ['raw', 'media_path', 'transcript']) if (!cols.has(c)) db.exec(`ALTER TABLE messages ADD COLUMN ${c} TEXT`)
  return db
}

export const MEDIA = path.join(DATA, 'media')
mkdirSync(MEDIA, { recursive: true })

// "123@lid" -> "5511...@s.whatsapp.net" quando o mapeamento é conhecido.
export function canonJid (db, jid) {
  if (!jid || !jid.endsWith('@lid')) return jid
  const r = db.prepare('SELECT pn FROM lid_map WHERE lid = ?').get(jid)
  return r ? r.pn : jid
}
