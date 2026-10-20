/** Turn LiteLLM/Ollama nested JSON errors into readable chat messages. */

function tryParseJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown
  } catch {
    return null
  }
}

function digMessage(value: unknown, depth = 0): string | null {
  if (depth > 6 || value == null) return null
  if (typeof value === 'string') {
    const trimmed = value.trim()
    if (!trimmed) return null
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      const nested = digMessage(tryParseJson(trimmed), depth + 1)
      if (nested) return nested
    }
    return trimmed
  }
  if (typeof value === 'object') {
    const o = value as Record<string, unknown>
    for (const key of ['message', 'error', 'detail', 'msg']) {
      if (key in o) {
        const found = digMessage(o[key], depth + 1)
        if (found) return found
      }
    }
  }
  return null
}

export function formatAiError(raw: unknown, httpStatus?: number): string {
  let text = ''
  if (typeof raw === 'string') text = raw
  else if (raw && typeof raw === 'object') {
    const o = raw as Record<string, unknown>
    text =
      digMessage(o.detail) ??
      digMessage(o.error) ??
      digMessage(o.message) ??
      JSON.stringify(raw)
  } else {
    text = String(raw ?? 'Request failed')
  }

  const inner = digMessage(text) ?? text
  const lower = inner.toLowerCase()

  if (lower.includes('timeout') || lower.includes('timed out')) {
    return 'The model took too long to respond. Try again shortly.'
  }
  if (lower.includes('apiconnectionerror')) {
    return 'Could not reach the model backend on the cluster. Please retry shortly.'
  }

  const cleaned = inner.replace(/^litellm\.\w+:\s*/i, '').trim()
  if (httpStatus && httpStatus >= 500 && !cleaned.toLowerCase().startsWith('http')) {
    return cleaned.length > 400 ? `${cleaned.slice(0, 400)}...` : cleaned
  }
  return cleaned.length > 500 ? `${cleaned.slice(0, 500)}...` : cleaned
}
