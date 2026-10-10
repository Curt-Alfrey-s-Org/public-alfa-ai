import { useEffect, useMemo, useRef } from 'react'
import {
  buildSwirlParticles,
  drawSwirlNebula,
  SWIRL_PARTICLE_COUNT,
} from './swirlNebulaCanvas'

const ORB_PX = 40

function usePrefersReducedMotion(): boolean {
  return useMemo(() => {
    if (typeof window === 'undefined') return false
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }, [])
}

/** ALFa thinking indicator: dense blue nebula swirl (aesthetic only; no encoded data). */
export function QuantumOrbLoader() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const reducedMotion = usePrefersReducedMotion()
  const particles = useMemo(() => buildSwirlParticles(SWIRL_PARTICLE_COUNT), [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const dpr = window.devicePixelRatio || 1
    canvas.width = ORB_PX * dpr
    canvas.height = ORB_PX * dpr
    canvas.style.width = `${ORB_PX}px`
    canvas.style.height = `${ORB_PX}px`

    const ctx = canvas.getContext('2d')
    if (!ctx) return

    if (reducedMotion) {
      drawSwirlNebula(ctx, ORB_PX, particles, 0, false)
      return
    }

    let raf = 0
    const start = performance.now()

    const frame = (now: number) => {
      drawSwirlNebula(ctx, ORB_PX, particles, (now - start) / 1000, true)
      raf = requestAnimationFrame(frame)
    }

    raf = requestAnimationFrame(frame)
    return () => cancelAnimationFrame(raf)
  }, [particles, reducedMotion])

  return (
    <div className="quantum-orb-loader" role="status" aria-label="AI is thinking">
      <canvas ref={canvasRef} className="quantum-orb-loader__canvas" aria-hidden="true" />
    </div>
  )
}
