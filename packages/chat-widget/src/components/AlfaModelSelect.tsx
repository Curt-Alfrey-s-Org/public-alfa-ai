import type { ChatModelId, ChatModelOption } from '../types'

type AlfaModelSelectProps = {
  models: ChatModelOption[]
  value: ChatModelId
  onChange: (id: ChatModelId) => void
  disabled?: boolean
}

/**
 * Model picker. Only rendered when the single-source admin flag
 * (config.showModelPicker) is set; consumer users never see this.
 */
export function AlfaModelSelect({
  models,
  value,
  onChange,
  disabled = false,
}: AlfaModelSelectProps) {
  if (models.length === 0) return null

  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      disabled={disabled}
      aria-label="Chat model"
      className="max-w-[11rem] rounded-full border border-slate-600 bg-slate-800 px-2.5 py-0.5 text-xs text-slate-300 focus:outline-none focus:ring-1 focus:ring-sky-500 disabled:opacity-50"
    >
      {models.map((m) => (
        <option key={m.id} value={m.id} disabled={!m.available}>
          {m.label}
          {!m.available ? ' (offline)' : ''}
        </option>
      ))}
    </select>
  )
}
