/**
 * Per-app configuration for the shared ALFa chat widget. Each consumer wraps
 * its app once in <AlfaWidgetProvider config={...}> and supplies only the
 * app-specific bits (auth token resolver, storage prefix, page hints, avatar,
 * admin flag). Everything visual/behavioral comes from the package.
 */

import { createContext, useContext, type ReactNode } from 'react'
import type { AskAIPageId } from './types'

export type AlfaWidgetConfig = {
  /** Header/launcher label. Default: "ALFa AI". */
  brandLabel?: string
  /** Web path to the ALFa avatar. Default: "/branding/alfa-ai-avatar.png". */
  avatarSrc?: string
  /** Same-origin base path for the app's narrative API. Default "/api/ai-narrative". */
  apiBasePath?: string
  /** localStorage key prefix, e.g. "contracts_bot". Default "alfa". */
  storagePrefix?: string
  /** Resolve auth headers for the app (each app has its own auth). */
  getAuthHeaders: () => Record<string, string> | undefined
  /**
   * Whether THIS user is the single-source admin who may pick the model.
   * Consumer apps leave this false; only the ALFa brain admin surface sets true.
   */
  showModelPicker?: boolean
  /** Called when the session has no token (e.g. to trigger logout). */
  onUnauthenticated?: () => void
  /** Optional per-page copy overrides. */
  pageHint?: (page: AskAIPageId) => string
  placeholder?: (page: AskAIPageId) => string
  emptyStateHint?: (page: AskAIPageId) => string
  /** Popup window route. Default "/alfa-chat". */
  popupPath?: string
}

type ResolvedConfig = Required<
  Omit<AlfaWidgetConfig, 'getAuthHeaders' | 'onUnauthenticated'>
> & {
  getAuthHeaders: () => Record<string, string> | undefined
  onUnauthenticated?: () => void
}

const DEFAULT_HINT = 'Ask ALFa AI about this app.'

function defaultPageHint(): string {
  return DEFAULT_HINT
}
function defaultPlaceholder(): string {
  return 'Message ALFa AI...'
}
function defaultEmptyStateHint(): string {
  return DEFAULT_HINT
}

const AlfaWidgetConfigContext = createContext<ResolvedConfig | null>(null)

export function AlfaWidgetProvider({
  config,
  children,
}: {
  config: AlfaWidgetConfig
  children: ReactNode
}) {
  const resolved: ResolvedConfig = {
    brandLabel: config.brandLabel ?? 'ALFa AI',
    avatarSrc: config.avatarSrc ?? '/branding/alfa-ai-avatar.png',
    apiBasePath: config.apiBasePath ?? '/api/ai-narrative',
    storagePrefix: config.storagePrefix ?? 'alfa',
    getAuthHeaders: config.getAuthHeaders,
    showModelPicker: config.showModelPicker ?? false,
    onUnauthenticated: config.onUnauthenticated,
    pageHint: config.pageHint ?? defaultPageHint,
    placeholder: config.placeholder ?? defaultPlaceholder,
    emptyStateHint: config.emptyStateHint ?? defaultEmptyStateHint,
    popupPath: config.popupPath ?? '/alfa-chat',
  }
  return (
    <AlfaWidgetConfigContext.Provider value={resolved}>
      {children}
    </AlfaWidgetConfigContext.Provider>
  )
}

export function useAlfaWidgetConfig(): ResolvedConfig {
  const ctx = useContext(AlfaWidgetConfigContext)
  if (!ctx) {
    throw new Error('ALFa chat widget must be used within <AlfaWidgetProvider>')
  }
  return ctx
}
