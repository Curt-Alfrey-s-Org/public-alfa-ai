/** Canvas particle nebula for ALFa "thinking" indicator (aesthetic only; no encoded data). */

export type SwirlParticle = {
  baseAngle: number
  radiusNorm: number
  layerSpeed: number
  size: number
  color: string
  twinklePhase: number
  driftAmp: number
  driftFreq: number
}

const COLORS = ['#0ea5e9', '#38bdf8', '#67e8f9', '#22d3ee', '#0284c7'] as const

export function buildSwirlParticles(count: number): SwirlParticle[] {
  const golden = Math.PI * (3 - Math.sqrt(5))
  const layerSpeeds = [0.55, -0.32, 0.18]

  return Array.from({ length: count }, (_, i) => {
    const y = 1 - (i / Math.max(count - 1, 1)) * 2
    const ring = Math.sqrt(Math.max(0, 1 - y * y))
    const theta = golden * i
    const radiusNorm = 0.12 + ring * 0.88
    const depth = (Math.sin(theta) * ring + 1) / 2
    const layer = i % 3

    return {
      baseAngle: theta + layer * 1.7,
      radiusNorm,
      layerSpeed: layerSpeeds[layer]!,
      size: 0.45 + depth * 1.35 + (i % 5) * 0.08,
      color: COLORS[i % COLORS.length]!,
      twinklePhase: (i * 0.41) % (Math.PI * 2),
      driftAmp: 0.015 + (i % 7) * 0.004,
      driftFreq: 0.6 + (i % 11) * 0.07,
    }
  })
}

function edgeFade(radiusNorm: number): number {
  if (radiusNorm < 0.55) return 1
  if (radiusNorm > 0.95) return 0.08
  return 1 - (radiusNorm - 0.55) / 0.4
}

export function drawSwirlNebula(
  ctx: CanvasRenderingContext2D,
  size: number,
  particles: SwirlParticle[],
  timeSec: number,
  animated: boolean
): void {
  const dpr = typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1
  const px = size * dpr
  ctx.clearRect(0, 0, px, px)

  const cx = px / 2
  const cy = px / 2
  const maxR = px * 0.42
  const t = animated ? timeSec : 0

  const coreGrad = ctx.createRadialGradient(cx, cy, 0, cx, cy, maxR * 1.15)
  coreGrad.addColorStop(0, 'rgba(56, 189, 248, 0.35)')
  coreGrad.addColorStop(0.35, 'rgba(14, 165, 233, 0.12)')
  coreGrad.addColorStop(0.72, 'rgba(2, 132, 199, 0.04)')
  coreGrad.addColorStop(1, 'rgba(10, 24, 56, 0)')
  ctx.fillStyle = coreGrad
  ctx.fillRect(0, 0, px, px)

  ctx.save()
  ctx.beginPath()
  ctx.arc(cx, cy, maxR * 1.05, 0, Math.PI * 2)
  ctx.clip()

  for (const p of particles) {
    const breathe = animated ? 0.88 + 0.12 * Math.sin(t * 0.75 + p.baseAngle * 2) : 1
    const r = p.radiusNorm * breathe * maxR
    const angle =
      p.baseAngle + t * p.layerSpeed + Math.sin(t * p.driftFreq + p.twinklePhase) * 0.35
    const driftX = animated ? Math.sin(t * p.driftFreq + p.baseAngle) * p.driftAmp * px : 0
    const driftY = animated ? Math.cos(t * p.driftFreq * 1.1 + p.baseAngle) * p.driftAmp * px : 0
    const x = cx + Math.cos(angle) * r + driftX
    const y = cy + Math.sin(angle) * r * 0.94 + driftY

    const twinkle = animated
      ? 0.55 + 0.45 * Math.sin(t * 2.4 + p.twinklePhase)
      : 0.75
    const alpha = edgeFade(p.radiusNorm) * twinkle * (p.radiusNorm < 0.4 ? 1 : 0.82)
    const dotR = p.size * dpr

    ctx.beginPath()
    ctx.arc(x, y, dotR, 0, Math.PI * 2)
    ctx.fillStyle = p.color
    ctx.globalAlpha = Math.min(1, alpha)
    ctx.shadowColor = p.color
    ctx.shadowBlur = dotR * 2.2
    ctx.fill()
    ctx.shadowBlur = 0
    ctx.globalAlpha = 1
  }

  ctx.restore()
}

export const SWIRL_PARTICLE_COUNT = 150
