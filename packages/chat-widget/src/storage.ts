import type { AskAIPageId, ChatMessage } from './types'

export const NARRATIVE_TIMEOUT_MS = 1_200_000

const MAX_THREADS = 8
const MAX_MESSAGES_PER_THREAD = 80

type ThreadStore = Record<string, ChatMessage[]>

function threadsKey(prefix: string): string {
  return `${prefix}_alfa_chat_v2`
}
function popupKey(prefix: string): string {
  return `${prefix}_alfa_chat_popup_ctx`
}

function readAllThreads(prefix: string): ThreadStore {
  try {
    const raw = localStorage.getItem(threadsKey(prefix))
    if (!raw) return {}
    const parsed = JSON.parse(raw) as unknown
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as ThreadStore
    }
  } catch {
    /* ignore */
  }
  return {}
}

function writeAllThreads(prefix: string, store: ThreadStore): void {
  try {
    const keys = Object.keys(store)
    if (keys.length > MAX_THREADS) {
      const trimmed: ThreadStore = {}
      for (const k of keys.slice(-MAX_THREADS)) {
        trimmed[k] = store[k]!
      }
      store = trimmed
    }
    localStorage.setItem(threadsKey(prefix), JSON.stringify(store))
  } catch {
    /* quota */
  }
}

export function makeThreadKey(account: string, page: AskAIPageId, playerName: string): string {
  const u = (account || '').trim().toLowerCase()
  const p = page === 'general' ? '_general' : (playerName || '').trim().toLowerCase()
  return `${u}:${page}:${p}`
}

export function loadThread(prefix: string, threadKey: string): ChatMessage[] {
  const thread = readAllThreads(prefix)[threadKey]
  if (!Array.isArray(thread)) return []
  return thread.filter(
    (m) =>
      m &&
      typeof m === 'object' &&
      (m.role === 'user' || m.role === 'assistant') &&
      typeof m.content === 'string'
  )
}

export function saveThread(prefix: string, threadKey: string, messages: ChatMessage[]): void {
  const store = readAllThreads(prefix)
  const trimmed =
    messages.length > MAX_MESSAGES_PER_THREAD
      ? messages.slice(-MAX_MESSAGES_PER_THREAD)
      : messages
  store[threadKey] = trimmed
  writeAllThreads(prefix, store)
}

export function clearThread(prefix: string, threadKey: string): void {
  const store = readAllThreads(prefix)
  delete store[threadKey]
  writeAllThreads(prefix, store)
}

export function newMessageId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`
}

export type PopupChatContext = {
  page: AskAIPageId
  playerName: string
  context: Record<string, unknown>
}

export function stashPopupContext(prefix: string, ctx: PopupChatContext): void {
  try {
    sessionStorage.setItem(popupKey(prefix), JSON.stringify(ctx))
  } catch {
    /* ignore */
  }
}

export function readPopupContext(prefix: string): PopupChatContext | null {
  try {
    const raw = sessionStorage.getItem(popupKey(prefix))
    if (!raw) return null
    const parsed = JSON.parse(raw) as PopupChatContext
    if (!parsed?.page) return null
    return {
      page: parsed.page,
      playerName: parsed.playerName ?? '',
      context: parsed.context ?? {},
    }
  } catch {
    return null
  }
}
