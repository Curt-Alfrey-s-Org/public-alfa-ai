/**
 * @alfa-ai/chat-widget - the single source of truth for the ALFa AI chat window
 * used by every consumer app. Owned by alfa-ai. Edit here, publish to Verdaccio,
 * rebuild consumers.
 *
 * Consumers must also:
 *   import '@alfa-ai/chat-widget/styles.css'
 *   add this package to their Tailwind `content` globs (see README).
 */

export { AlfaWidgetProvider, useAlfaWidgetConfig } from './config'
export type { AlfaWidgetConfig } from './config'

export {
  AlfaAskAiProvider,
  useAlfaAskAiContext,
  useOptionalAlfaAskAiContext,
  useAlfaAskAiRegistration,
} from './context'
export type { AlfaAskAiRegistration } from './context'

export { AlfaAskAiDock } from './components/AlfaAskAiDock'
export type { AlfaAskAiDockProps } from './components/AlfaAskAiDock'
export { AlfaChatPanel } from './components/AlfaChatPanel'
export type { AlfaChatPanelProps } from './components/AlfaChatPanel'
export { AlfaChatPopup } from './components/AlfaChatPopup'
export { AlfaChatInput } from './components/AlfaChatInput'
export { AlfaChatMessage } from './components/AlfaChatMessage'
export { AlfaModelSelect } from './components/AlfaModelSelect'
export { QuantumOrbLoader } from './components/QuantumOrbLoader'

export {
  ALFA_PANEL_BG,
  ALFA_HEADER_BG,
  ALFA_PANEL_BORDER,
  ALFA_DOCK_WIDTH,
  ALFA_DOCK_HEIGHT,
  alfaPanelStyle,
  alfaHeaderStyle,
  alfaLauncherStyle,
} from './theme'

export { CHAT_MODEL_27B, CHAT_MODEL_35B } from './types'
export type {
  AskAIPageId,
  ChatModelId,
  ChatModelOption,
  ChatMessage,
  ChatRole,
  ModelsResponse,
  AskNarrativePayload,
} from './types'

export { NARRATIVE_TIMEOUT_MS } from './storage'
export { formatAiError } from './errorFormat'
export { createAlfaApi } from './api'
