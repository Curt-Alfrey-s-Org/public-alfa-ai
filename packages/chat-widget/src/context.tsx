/**
 * Global ALFa AI dock registration: pages register their active context so the
 * single fixed dock knows what the user is looking at.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import type { AskAIPageId } from './types'

export type AlfaAskAiRegistration = {
  page: AskAIPageId
  playerName: string
  context: Record<string, unknown>
} | null

type Ctx = {
  registration: AlfaAskAiRegistration
  setRegistration: (r: AlfaAskAiRegistration) => void
}

const AlfaAskAiContext = createContext<Ctx | null>(null)

export function AlfaAskAiProvider({ children }: { children: ReactNode }) {
  const [registration, setRegistration] = useState<AlfaAskAiRegistration>(null)
  const stableSet = useCallback((r: AlfaAskAiRegistration) => {
    setRegistration((prev) => (prev === r ? prev : r))
  }, [])
  const value = useMemo(
    () => ({ registration, setRegistration: stableSet }),
    [registration, stableSet]
  )
  return <AlfaAskAiContext.Provider value={value}>{children}</AlfaAskAiContext.Provider>
}

export function useAlfaAskAiContext(): Ctx {
  const ctx = useContext(AlfaAskAiContext)
  if (!ctx) {
    throw new Error('useAlfaAskAiContext must be used within AlfaAskAiProvider')
  }
  return ctx
}

export function useOptionalAlfaAskAiContext(): Ctx | null {
  return useContext(AlfaAskAiContext)
}

/**
 * Register this page as the source for ALFa AI (page snapshot).
 * Pass null to clear when leaving the screen.
 */
export function useAlfaAskAiRegistration(reg: AlfaAskAiRegistration) {
  const ctx = useOptionalAlfaAskAiContext()
  const setRegistration = ctx?.setRegistration
  const serialized = useMemo(() => {
    if (!reg) return ''
    try {
      return JSON.stringify({
        page: reg.page,
        playerName: reg.playerName,
        context: reg.context,
      })
    } catch {
      return String(reg.page) + reg.playerName
    }
  }, [reg])

  useEffect(() => {
    if (!setRegistration) return
    setRegistration(reg)
    return () => {
      setRegistration(null)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [setRegistration, serialized])
}
