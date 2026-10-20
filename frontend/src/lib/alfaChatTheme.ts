/**
 * Brain SPA chat chrome colors — MUST stay in sync with
 * packages/chat-widget/src/theme.ts (single source for package consumers).
 *
 * Full-page guest/signed-in chat uses viewport height (GuestChat h-screen),
 * not ALFA_DOCK_WIDTH / ALFA_DOCK_HEIGHT (consumer floating dock only).
 */

import type { CSSProperties } from 'react'

export const ALFA_PANEL_BG = '#0a1838'
export const ALFA_HEADER_BG = '#07122c'
export const ALFA_PANEL_BORDER = '#142452'
export const ALFA_AVATAR_SRC = '/alfa-ai/branding/alfa-ai-avatar.png'

export const alfaPanelStyle: CSSProperties = {
  backgroundColor: ALFA_PANEL_BG,
  borderColor: ALFA_PANEL_BORDER,
}

export const alfaHeaderStyle: CSSProperties = {
  backgroundColor: ALFA_HEADER_BG,
  borderColor: ALFA_PANEL_BORDER,
}

export const alfaCardStyle: CSSProperties = {
  backgroundColor: ALFA_PANEL_BG,
  borderColor: ALFA_PANEL_BORDER,
}

export const alfaLauncherStyle: CSSProperties = {
  backgroundColor: ALFA_PANEL_BG,
  borderColor: ALFA_PANEL_BORDER,
}
