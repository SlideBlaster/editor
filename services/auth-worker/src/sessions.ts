/**
 * Session + pending-OAuth store. Contract: sessions.md.
 *
 * The signed-in user's GitHub token stays **server-side** here (never in a client
 * cookie): the `sb_session` cookie carries only the opaque key. Two backends share
 * one interface — Workers KV (production) and an in-memory map (tests / `node`).
 */
import type { Identity } from './config'
import { randomToken } from './encoding'

export interface SessionRecord {
  userToken: string
  identity: Identity
  csrf: string
  createdAt: number
}

export interface SessionStore {
  /** Create a session; returns its id + csrf. */
  create(rec: { userToken: string; identity: Identity }): Promise<{ id: string; csrf: string }>
  get(id: string | null): Promise<SessionRecord | null>
  delete(id: string | null): Promise<void>
  /** Stash `return_to` before the GitHub redirect; returns the state nonce. */
  putPending(returnTo: string): Promise<string>
  /** Consume a pending handoff by state nonce (single use). */
  takePending(state: string | null): Promise<string | null>
}

const SESSION_TTL_S = 60 * 60 * 24
const PENDING_TTL_S = 600

interface KVLike {
  get(key: string, type: 'json'): Promise<unknown>
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>
  delete(key: string): Promise<void>
}

/** KV-backed store (production). */
export function createKvSessionStore(kv: KVLike): SessionStore {
  return {
    async create({ userToken, identity }) {
      const id = randomToken()
      const csrf = randomToken()
      const record: SessionRecord = { userToken, identity, csrf, createdAt: Date.now() }
      await kv.put(`sess:${id}`, JSON.stringify(record), { expirationTtl: SESSION_TTL_S })
      return { id, csrf }
    },
    async get(id) {
      if (!id) return null
      return (await kv.get(`sess:${id}`, 'json')) as SessionRecord | null
    },
    async delete(id) {
      if (id) await kv.delete(`sess:${id}`)
    },
    async putPending(returnTo) {
      const state = randomToken()
      await kv.put(`pending:${state}`, JSON.stringify({ returnTo }), {
        expirationTtl: PENDING_TTL_S,
      })
      return state
    },
    async takePending(state) {
      if (!state) return null
      const rec = (await kv.get(`pending:${state}`, 'json')) as { returnTo: string } | null
      if (rec) await kv.delete(`pending:${state}`)
      return rec?.returnTo ?? null
    },
  }
}

/** In-memory store for tests and the `node` dev entry. */
export function createMemorySessionStore(): SessionStore {
  const sessions = new Map<string, SessionRecord>()
  const pending = new Map<string, string>()
  return {
    async create({ userToken, identity }) {
      const id = randomToken()
      const csrf = randomToken()
      sessions.set(id, { userToken, identity, csrf, createdAt: Date.now() })
      return { id, csrf }
    },
    async get(id) {
      return id ? (sessions.get(id) ?? null) : null
    },
    async delete(id) {
      if (id) sessions.delete(id)
    },
    async putPending(returnTo) {
      const state = randomToken()
      pending.set(state, returnTo)
      return state
    },
    async takePending(state) {
      if (!state) return null
      const returnTo = pending.get(state) ?? null
      if (returnTo !== null) pending.delete(state)
      return returnTo
    },
  }
}
