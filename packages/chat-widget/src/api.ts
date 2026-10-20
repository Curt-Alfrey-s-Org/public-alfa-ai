import { formatAiError } from './errorFormat'
import type { AskNarrativePayload, ModelsResponse } from './types'

type AuthHeaders = () => Record<string, string> | undefined

/**
 * Same-origin narrative API client. Base path is per-app (default
 * "/api/ai-narrative"); auth headers are injected by the host app.
 */
export function createAlfaApi(apiBasePath: string, getAuthHeaders: AuthHeaders) {
  const base = apiBasePath.replace(/\/$/, '')

  async function fetchChatModels(): Promise<ModelsResponse> {
    const headers = getAuthHeaders()
    if (!headers) {
      return { litellm_enabled: false, models: [] }
    }
    const res = await fetch(`${base}/models`, { headers })
    if (!res.ok) {
      throw new Error(`Failed to load models (${res.status})`)
    }
    return (await res.json()) as ModelsResponse
  }

  async function askNarrative(
    payload: AskNarrativePayload,
    signal: AbortSignal
  ): Promise<{ answer: string; error?: string }> {
    const headers = getAuthHeaders()
    if (!headers) throw new Error('Not authenticated')

    const res = await fetch(`${base}/ask`, {
      method: 'POST',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal,
    })
    const data = (await res.json().catch(() => ({}))) as {
      answer?: string
      error?: string
      detail?: unknown
    }
    if (!res.ok) {
      throw new Error(formatAiError(data.detail ?? data.error ?? data, res.status))
    }
    if (data.error) throw new Error(formatAiError(data.error))
    return { answer: (data.answer || '').trim() }
  }

  return { fetchChatModels, askNarrative }
}
