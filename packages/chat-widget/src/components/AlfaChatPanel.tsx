import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAlfaWidgetConfig } from '../config'
import { createAlfaApi } from '../api'
import { AlfaChatInput } from './AlfaChatInput'
import { AlfaChatMessage } from './AlfaChatMessage'
import { QuantumOrbLoader } from './QuantumOrbLoader'
import {
  clearThread,
  loadThread,
  makeThreadKey,
  newMessageId,
  NARRATIVE_TIMEOUT_MS,
  saveThread,
} from '../storage'
import type { AskAIPageId, ChatMessage, ChatModelId, ChatModelOption } from '../types'

export type AlfaChatPanelProps = {
  page: AskAIPageId
  playerName?: string
  context: Record<string, unknown>
  className?: string
  variant?: 'docked' | 'inline' | 'expanded'
  /** Account label used to namespace stored threads. */
  accountLabel?: string
  /** When set, model state is owned by the parent (dock header picker). */
  selectedModel?: ChatModelId
  onModelChange?: (id: ChatModelId) => void
  modelOptions?: ChatModelOption[]
  modelsLoading?: boolean
}

const MAX_HISTORY_TURNS = 8

function firstAvailable(models: ChatModelOption[]): ChatModelId | '' {
  return models.find((m) => m.available)?.id ?? models[0]?.id ?? ''
}

export function AlfaChatPanel({
  page,
  playerName = '',
  context,
  className = '',
  variant = 'docked',
  accountLabel = '',
  selectedModel: selectedModelProp,
  onModelChange,
  modelOptions: modelOptionsProp,
  modelsLoading: modelsLoadingProp,
}: AlfaChatPanelProps) {
  const config = useAlfaWidgetConfig()
  const { avatarSrc, storagePrefix, getAuthHeaders, showModelPicker } = config
  const api = useMemo(
    () => createAlfaApi(config.apiBasePath, getAuthHeaders),
    [config.apiBasePath, getAuthHeaders]
  )

  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [internalModelOptions, setInternalModelOptions] = useState<ChatModelOption[]>([])
  const [internalSelectedModel, setInternalSelectedModel] = useState<ChatModelId>('')
  const [internalModelsLoading, setInternalModelsLoading] = useState(true)
  const bottomRef = useRef<HTMLDivElement>(null)

  const modelOptions = modelOptionsProp ?? internalModelOptions
  const modelsLoading = modelsLoadingProp ?? internalModelsLoading
  const selectedModel = selectedModelProp ?? internalSelectedModel

  const authHeaders = useMemo(() => getAuthHeaders(), [getAuthHeaders])
  const canUse = !!authHeaders

  const threadKey = useMemo(
    () => makeThreadKey(accountLabel, page, page === 'general' ? '' : playerName),
    [accountLabel, page, playerName]
  )

  useEffect(() => {
    setMessages(loadThread(storagePrefix, threadKey))
    setError(null)
  }, [storagePrefix, threadKey])

  useEffect(() => {
    saveThread(storagePrefix, threadKey, messages)
  }, [storagePrefix, messages, threadKey])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: loading ? 'auto' : 'smooth' })
  }, [messages, loading, error])

  // Fetch + auto-select the central model when the parent does not manage it.
  useEffect(() => {
    if (modelOptionsProp !== undefined) return
    if (!canUse) {
      setInternalModelsLoading(false)
      return
    }
    let cancelled = false
    setInternalModelsLoading(true)
    api
      .fetchChatModels()
      .then((data) => {
        if (cancelled) return
        setInternalModelOptions(data.models)
        setInternalSelectedModel((prev) =>
          prev && data.models.some((m) => m.id === prev && m.available)
            ? prev
            : firstAvailable(data.models)
        )
      })
      .catch(() => {
        if (!cancelled) setInternalModelOptions([])
      })
      .finally(() => {
        if (!cancelled) setInternalModelsLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [api, canUse, modelOptionsProp])

  const selectedModelMeta = useMemo(
    () => modelOptions.find((m) => m.id === selectedModel),
    [modelOptions, selectedModel]
  )
  const modelReady = selectedModelMeta?.available === true

  const handleModelChange = useCallback(
    (id: ChatModelId) => {
      if (onModelChange) onModelChange(id)
      else setInternalSelectedModel(id)
    },
    [onModelChange]
  )

  const sendQuestion = useCallback(
    async (question: string, historyBefore: ChatMessage[]) => {
      if (!canUse || loading || !modelReady) return
      const q = question.trim()
      if (!q) return

      setLoading(true)
      setError(null)

      const userMsg: ChatMessage = {
        id: newMessageId(),
        role: 'user',
        content: q,
        createdAt: Date.now(),
      }
      setMessages((prev) => [...prev, userMsg])

      try {
        const { answer: a } = await api.askNarrative(
          {
            page,
            player_name: page === 'general' ? '' : playerName.trim(),
            question: q,
            context,
            history: historyBefore
              .slice(-MAX_HISTORY_TURNS)
              .map((m) => ({ role: m.role, content: m.content })),
            model: selectedModel,
          },
          AbortSignal.timeout(NARRATIVE_TIMEOUT_MS)
        )
        if (!a) throw new Error('No answer returned')

        setMessages((prev) => [
          ...prev,
          { id: newMessageId(), role: 'assistant', content: a, createdAt: Date.now() },
        ])
      } catch (e) {
        setMessages((prev) => prev.filter((m) => m.id !== userMsg.id))
        if (e instanceof DOMException && e.name === 'TimeoutError') {
          setError('Request timed out - ALFa may still be processing on the cluster.')
        } else {
          setError(e instanceof Error ? e.message : 'Something went wrong')
        }
      } finally {
        setLoading(false)
      }
    },
    [api, canUse, context, loading, modelReady, page, playerName, selectedModel]
  )

  const onClearHistory = useCallback(() => {
    if (loading) return
    setMessages([])
    clearThread(storagePrefix, threadKey)
    setError(null)
  }, [loading, storagePrefix, threadKey])

  if (!canUse) {
    return (
      <div className={`space-y-2 text-sm text-amber-200/90 ${className}`}>
        <p>Sign in again to use ALFa AI - your session has no API token.</p>
        {config.onUnauthenticated && (
          <button
            type="button"
            onClick={() => config.onUnauthenticated?.()}
            className="rounded-md border border-amber-500/40 px-3 py-1.5 text-xs font-medium text-amber-100 hover:bg-amber-950/40"
          >
            Sign out and log in again
          </button>
        )}
      </div>
    )
  }

  // Footer picker only for the single-source admin, and only when the parent
  // (dock header) is not already rendering the model controls.
  const showFooterPicker = showModelPicker && modelOptionsProp === undefined && modelOptions.length > 0

  return (
    <div className={`flex flex-col h-full min-h-0 select-text ${className}`}>
      <div className="flex-1 overflow-y-auto min-h-0 px-1 py-2">
        <div className="space-y-4">
          {messages.length === 0 && !loading && (
            <div className="flex flex-col items-center justify-center py-8 text-center">
              <img
                src={avatarSrc}
                alt={config.brandLabel}
                className={`mb-3 rounded-full object-cover ${variant === 'docked' ? 'h-12 w-12' : 'h-16 w-16'}`}
              />
              <h2 className="text-base font-semibold text-slate-200">How can I help you?</h2>
              <p className="mt-2 max-w-xs text-xs text-slate-400 leading-relaxed">
                {config.emptyStateHint(page)}
              </p>
            </div>
          )}

          {messages.map((msg, idx) => (
            <AlfaChatMessage
              key={msg.id}
              role={msg.role}
              content={msg.content}
              editable={msg.role === 'user'}
              disabled={loading}
              onEdit={(newContent) => {
                const historyBefore = messages.slice(0, idx)
                setMessages(historyBefore)
                void sendQuestion(newContent, historyBefore)
              }}
            />
          ))}

          {loading && (
            <div className="flex justify-start pl-11">
              <div className="rounded-2xl bg-slate-800 px-4 py-2">
                <QuantumOrbLoader />
              </div>
            </div>
          )}

          {error && (
            <div className="rounded-xl border border-red-800/50 bg-red-950/30 px-4 py-3 text-sm text-red-300">
              {error}
            </div>
          )}

          <div ref={bottomRef} />
        </div>
      </div>

      <div className="shrink-0 border-t border-slate-700/60 pt-3 mt-2 space-y-2">
        {showFooterPicker && (
          <div className="flex items-center justify-between gap-2 px-1">
            <select
              value={selectedModel}
              onChange={(e) => handleModelChange(e.target.value)}
              disabled={loading || modelsLoading}
              aria-label="Chat model"
              className="rounded-full border border-slate-600 bg-slate-800 px-2.5 py-0.5 text-xs text-slate-300 focus:outline-none focus:ring-1 focus:ring-sky-500"
            >
              {modelOptions.map((m) => (
                <option key={m.id} value={m.id} disabled={!m.available}>
                  {m.label}
                  {!m.available ? ' (offline)' : ''}
                </option>
              ))}
            </select>
            {messages.length > 0 && (
              <button
                type="button"
                onClick={onClearHistory}
                disabled={loading}
                className="text-[11px] text-slate-400 hover:text-red-300 disabled:opacity-50"
              >
                Clear history
              </button>
            )}
          </div>
        )}

        {!showFooterPicker && messages.length > 0 && (
          <div className="flex justify-end px-1">
            <button
              type="button"
              onClick={onClearHistory}
              disabled={loading}
              className="text-[11px] text-slate-400 hover:text-red-300 disabled:opacity-50"
            >
              Clear history
            </button>
          </div>
        )}

        <AlfaChatInput
          onSend={(text) => void sendQuestion(text, messages)}
          disabled={loading || !modelReady || modelsLoading}
          placeholder={config.placeholder(page)}
        />

        {modelsLoading && (
          <p className="text-center text-[10px] text-slate-500">Connecting to ALFa...</p>
        )}
        {!modelsLoading && !modelReady && (
          <p className="text-center text-[10px] text-amber-400/90">
            ALFa is warming up on the cluster - please retry shortly.
          </p>
        )}
      </div>
    </div>
  )
}
