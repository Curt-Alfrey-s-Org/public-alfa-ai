import { useEffect, useState } from 'react'
import { useAlfaWidgetConfig } from '../config'

type AlfaChatMessageProps = {
  role: 'user' | 'assistant'
  content: string
  editable?: boolean
  disabled?: boolean
  onEdit?: (newContent: string) => void
}

export function AlfaChatMessage({
  role,
  content,
  editable = false,
  disabled = false,
  onEdit,
}: AlfaChatMessageProps) {
  const { avatarSrc, brandLabel } = useAlfaWidgetConfig()
  const isUser = role === 'user'
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(content)

  useEffect(() => {
    if (!editing) setDraft(content)
  }, [content, editing])

  const saveEdit = () => {
    const trimmed = draft.trim()
    if (!trimmed || trimmed === content) {
      setEditing(false)
      return
    }
    onEdit?.(trimmed)
    setEditing(false)
  }

  return (
    <div className={`group flex gap-3 ${isUser ? 'justify-end' : 'justify-start'}`}>
      {!isUser && (
        <img
          src={avatarSrc}
          alt={brandLabel}
          className="mt-1 h-8 w-8 flex-shrink-0 rounded-full object-cover"
        />
      )}
      <div className={`max-w-[85%] ${isUser ? 'flex flex-col items-end gap-1' : ''}`}>
        <div
          className={`rounded-2xl px-4 py-3 ${
            isUser ? 'bg-sky-600 text-white' : 'bg-slate-800 text-slate-100'
          }`}
        >
          {isUser && editing ? (
            <div className="space-y-2">
              <textarea
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                rows={Math.min(8, Math.max(2, draft.split('\n').length))}
                className="w-full min-w-[12rem] resize-y rounded-lg border border-sky-400/40 bg-sky-700/50 px-2 py-1 text-sm text-white focus:outline-none focus:ring-1 focus:ring-sky-300"
                autoFocus
              />
              <div className="flex justify-end gap-2">
                <button
                  type="button"
                  onClick={() => {
                    setDraft(content)
                    setEditing(false)
                  }}
                  className="rounded px-2 py-0.5 text-xs text-sky-100 hover:bg-sky-500/40"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={saveEdit}
                  disabled={!draft.trim()}
                  className="rounded bg-white/20 px-2 py-0.5 text-xs font-medium text-white hover:bg-white/30 disabled:opacity-50"
                >
                  Save
                </button>
              </div>
            </div>
          ) : (
            <p className="whitespace-pre-wrap text-sm leading-relaxed">{content}</p>
          )}
        </div>
        {isUser && editable && !editing && !disabled && onEdit && (
          <button
            type="button"
            onClick={() => setEditing(true)}
            className="text-xs text-slate-500 opacity-0 transition hover:text-slate-300 group-hover:opacity-100"
          >
            Edit
          </button>
        )}
      </div>
    </div>
  )
}
