import { useMemo } from 'react'
import { useAlfaWidgetConfig } from '../config'
import { AlfaChatPanel } from './AlfaChatPanel'
import { readPopupContext } from '../storage'
import { alfaHeaderStyle, ALFA_PANEL_BG } from '../theme'

/**
 * Standalone popup page body (route "/alfa-chat"). Solid deep navy-royal.
 */
export function AlfaChatPopup({ accountLabel = '' }: { accountLabel?: string }) {
  const config = useAlfaWidgetConfig()
  const ctx = useMemo(() => readPopupContext(config.storagePrefix), [config.storagePrefix])
  const page = ctx?.page ?? 'general'
  const playerName = ctx?.playerName ?? ''
  const context = ctx?.context ?? {}

  return (
    <div
      className="h-dvh flex flex-col text-slate-50"
      style={{ backgroundColor: ALFA_PANEL_BG }}
    >
      <header
        className="shrink-0 flex items-center gap-3 border-b px-4 py-3"
        style={alfaHeaderStyle}
      >
        <img src={config.avatarSrc} alt={config.brandLabel} className="h-7 w-7 rounded-full object-cover" />
        <div className="min-w-0">
          <h1 className="text-sm font-bold text-sky-400">{config.brandLabel}</h1>
          <p className="text-xs text-slate-400 mt-0.5 truncate">{config.pageHint(page)}</p>
        </div>
      </header>
      <main className="flex-1 min-h-0 px-4 py-2 flex flex-col select-text">
        <AlfaChatPanel
          page={page}
          playerName={playerName}
          context={context}
          variant="expanded"
          accountLabel={accountLabel}
        />
      </main>
    </div>
  )
}
