/** Page id is a free-form string so each app can register its own pages. */
export type AskAIPageId = string

/** Approved LiteLLM tiers (aliases). Model choice is centrally controlled. */
export const CHAT_MODEL_27B = 'qwen3.6-27b'
/** @deprecated Retired 2026-07 -- remaps to 27B pool; do not use as a live target. */
export const CHAT_MODEL_35B = 'qwen3.6:35b-a3b'

/** Model ids are strings; the server (brain admin) governs the real list. */
export type ChatModelId = string

export type ChatModelOption = {
  id: ChatModelId
  label: string
  description?: string
  available: boolean
  reason?: string | null
}

export type ChatRole = 'user' | 'assistant'

export type ChatMessage = {
  id: string
  role: ChatRole
  content: string
  createdAt: number
}

export type ModelsResponse = {
  models: ChatModelOption[]
  litellm_enabled: boolean
}

export type AskNarrativePayload = {
  page: string
  player_name: string
  question: string
  context: Record<string, unknown>
  history: Array<{ role: ChatRole; content: string }>
  model: ChatModelId
}
