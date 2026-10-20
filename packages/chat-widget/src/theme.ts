/**
 * ALFa chat window signature colors - the SINGLE place to change the look
 * for every consumer app. Applied as inline styles so they render regardless
 * of each app's Tailwind purge/content config.
 *
 * Deep navy-royal (ALFaQD brand-blue family), fully opaque. No transparency,
 * no backdrop blur.
 */

import type { CSSProperties } from 'react'

export const ALFA_PANEL_BG = '#0a1838'
export const ALFA_HEADER_BG = '#07122c'
export const ALFA_PANEL_BORDER = '#142452'

/** Fixed consumer dock panel size — mirrors AlfaAskAiDock Tailwind classes. */
export const ALFA_DOCK_WIDTH = 'min(calc(100vw - 2rem), 28rem)'
export const ALFA_DOCK_HEIGHT = 'min(85dvh, 36rem)'

/** Convenience style objects for the panel shells. */
export const alfaPanelStyle: CSSProperties = {
  backgroundColor: ALFA_PANEL_BG,
  borderColor: ALFA_PANEL_BORDER,
}

export const alfaHeaderStyle: CSSProperties = {
  backgroundColor: ALFA_HEADER_BG,
  borderColor: ALFA_PANEL_BORDER,
}

export const alfaLauncherStyle: CSSProperties = {
  backgroundColor: ALFA_PANEL_BG,
  borderColor: ALFA_PANEL_BORDER,
}
