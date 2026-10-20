/**
 * Fixed bottom-right ALFa AI dock. Solid deep navy-royal panel (no
 * transparency). Model picker appears only for the single-source admin.
 */

import { useCallback, useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { useAlfaWidgetConfig } from '../config'
import { useOptionalAlfaAskAiContext } from '../context'
import { createAlfaApi } from '../api'
import { AlfaChatPanel } from './AlfaChatPanel'
import { AlfaModelSelect } from './AlfaModelSelect'
import { stashPopupContext } from '../storage'
import { alfaHeaderStyle, alfaLauncherStyle, alfaPanelStyle } from '../theme'
import type { AskAIPageId, ChatModelId, ChatModelOption } from '../types'

export type AlfaAskAiDockProps = {
  /** Gate the whole dock on host-app auth (e.g. only when logged in). */
  enabled?: boolean
  /** Account label to namespace stored chat threads. */
  accountLabel?: string
}

export function AlfaAskAiDock({ enabled = true, accountLabel = '' }: AlfaAskAiDockProps) {
  const config = useAlfaWidgetConfig()
  const { avatarSrc, brandLabel, showModelPicker, getAuthHeaders } = config
  const ctx = useOptionalAlfaAskAiContext()
  const api = useMemo(
    () => createAlfaApi(config.apiBasePath, getAuthHeaders),
    [config.apiBasePath, getAuthHeaders]
  )

  const [panelOpen, setPanelOpen] = useState(false)
  const [fullscreen, setFullscreen] = useState(false)
  const [modelOptions, setModelOptions] = useState<ChatModelOption[]>([])
  const [selectedModel, setSelectedModel] = useState<ChatModelId>('')
  const [modelsLoading, setModelsLoading] = useState(true)

  const registration = ctx?.registration
  const page: AskAIPageId = registration?.page ?? 'general'
  const playerName = registration?.playerName ?? ''
  const chatContext = registration?.context ?? {}
  const hint = config.pageHint(page)

  // Only the admin surface manages models at the dock level. Consumers let the
  // panel auto-select the central model.
  useEffect(() => {
    if (!showModelPicker || !enabled) return
    let cancelled = false
    setModelsLoading(true)
    api
      .fetchChatModels()
      .then((data) => {
        if (cancelled) return
        setModelOptions(data.models)
        setSelectedModel((prev) =>
          prev && data.models.some((m) => m.id === prev && m.available)
            ? prev
            : data.models.find((m) => m.available)?.id ?? data.models[0]?.id ?? ''
        )
      })
      .catch(() => {
        if (!cancelled) setModelOptions([])
      })
      .finally(() => {
        if (!cancelled) setModelsLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [api, showModelPicker, enabled])

  const openPopup = useCallback(() => {
    stashPopupContext(config.storagePrefix, { page, playerName, context: chatContext })
    const w = 520
    const h = 720
    const left = Math.max(0, window.screenX + window.outerWidth - w - 24)
    const top = Math.max(0, window.screenY + 24)
    window.open(
      config.popupPath,
      'alfa-ai-chat',
      `width=${w},height=${h},left=${left},top=${top},menubar=no,toolbar=no,location=no,status=no,resizable=yes,scrollbars=yes`
    )
  }, [config.popupPath, config.storagePrefix, page, playerName, chatContext])

  useEffect(() => {
    if (!fullscreen) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setFullscreen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [fullscreen])

  if (!ctx || !enabled) return null

  const onClose = () => (fullscreen ? setFullscreen(false) : setPanelOpen(false))

  const chrome = (
    <>
      <div
        className="flex items-center gap-3 border-b px-3 py-2.5 shrink-0"
        style={alfaHeaderStyle}
      >
        <img
          src={avatarSrc}
          alt={brandLabel}
          className="h-7 w-7 shrink-0 rounded-full object-cover"
        />
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-bold text-sky-400">{brandLabel}</span>
            {showModelPicker && (
              <AlfaModelSelect
                models={modelOptions}
                value={selectedModel}
                onChange={setSelectedModel}
                disabled={modelsLoading}
              />
            )}
          </div>
          <div className="text-[11px] text-slate-400 leading-snug truncate">{hint}</div>
        </div>
        <div className="flex items-center gap-0.5 shrink-0">
          <button
            type="button"
            onClick={openPopup}
            className="rounded-lg p-2 text-slate-300 hover:bg-white/10 hover:text-white"
            title="Open in popup window"
            aria-label="Open in popup window"
          >
            &#x29C9;
          </button>
          {!fullscreen && (
            <button
              type="button"
              onClick={() => setFullscreen(true)}
              className="rounded-lg p-2 text-slate-300 hover:bg-white/10 hover:text-white"
              title="Full screen"
              aria-label="Full screen"
            >
              &#x26F6;
            </button>
          )}
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-2 text-slate-300 hover:bg-white/10 hover:text-white"
            aria-label="Close ALFa AI"
          >
            &#x2715;
          </button>
        </div>
      </div>
      <div className="flex-1 overflow-hidden px-3 py-2 min-h-0 flex flex-col select-text">
        <AlfaChatPanel
          page={page}
          playerName={playerName}
          context={chatContext}
          variant="expanded"
          accountLabel={accountLabel}
          selectedModel={showModelPicker ? selectedModel : undefined}
          onModelChange={showModelPicker ? setSelectedModel : undefined}
          modelOptions={showModelPicker ? modelOptions : undefined}
          modelsLoading={showModelPicker ? modelsLoading : undefined}
        />
      </div>
    </>
  )

  const panelBody = (
    <div
      className={
        fullscreen
          ? 'fixed inset-0 z-[200] flex flex-col'
          : 'w-[min(calc(100vw-2rem),28rem)] h-[min(85dvh,36rem)] flex flex-col rounded-xl border shadow-2xl overflow-hidden text-slate-100'
      }
      style={alfaPanelStyle}
      role="dialog"
      aria-label={brandLabel}
      id="alfa-ai-dock-panel"
    >
      {chrome}
    </div>
  )

  return (
    <div
      className="fixed bottom-4 right-4 z-[90] flex flex-col items-end gap-2 pointer-events-none [&>*]:pointer-events-auto pb-[env(safe-area-inset-bottom,0)] pr-[env(safe-area-inset-right,0)]"
      aria-live="polite"
    >
      {panelOpen || fullscreen ? (
        fullscreen ? createPortal(panelBody, document.body) : panelBody
      ) : (
        <button
          type="button"
          onClick={() => setPanelOpen(true)}
          className="flex items-center gap-2 rounded-full border py-1.5 pl-1.5 pr-4 shadow-lg transition-colors hover:brightness-110"
          style={alfaLauncherStyle}
          aria-expanded={false}
          aria-controls="alfa-ai-dock-panel"
          title="Open ALFa AI"
        >
          <img src={avatarSrc} alt="" className="h-9 w-9 rounded-full object-cover" aria-hidden />
          <span className="text-sm font-semibold text-sky-400 tracking-wide">{brandLabel}</span>
        </button>
      )}
    </div>
  )
}
