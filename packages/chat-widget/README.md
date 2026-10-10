# @alfa-ai/chat-widget

The **single source of truth** for the ALFa AI chat window (dock + panel) used by
every consumer app in the cluster. Owned by **alfa-ai**; published to the cluster
Verdaccio registry. Edit here, publish, rebuild consumers - all windows change
together.

- Design spec: `alfa-ai/docs/ALFA_AI_CHAT_WIDGETS.md`
- Rollout runbook: `alfa-ai/.cursor/plans/UNIFIED_CHAT_WIDGET.md`

## What it provides

- Solid **deep navy-royal** dock (no transparency) - colors in `src/theme.ts`.
- Collapsed launcher pill + expanded panel + `/alfa-chat` popup + fullscreen.
- ALFa avatar shipped in the package (`assets/alfa-ai-avatar.png`).
- **Central, admin-only model selection**: consumer users get no picker; the
  model is auto-selected from the app's models endpoint. Only a surface that
  passes `showModelPicker` (the ALFa brain admin) can change tiers.

## Install (consumer app)

```bash
npm install @alfa-ai/chat-widget --registry http://hub
```

## Use (three steps)

1. Import styles once (e.g. in `main.tsx`):

```ts
import '@alfa-ai/chat-widget/styles.css'
```

2. Add the package to the app's Tailwind `content` globs so its utility classes
   are generated (`tailwind.config.js`):

```js
content: [
  './index.html',
  './src/**/*.{ts,tsx}',
  './node_modules/@alfa-ai/chat-widget/dist/**/*.{js,cjs}',
]
```

3. Wrap the app once and mount the dock:

```tsx
import {
  AlfaWidgetProvider,
  AlfaAskAiProvider,
  AlfaAskAiDock,
} from '@alfa-ai/chat-widget'
import { getAuthHeaders } from '@/lib/authToken'
import { useAuth } from '@/context/AuthContext'

function Shell() {
  const { user, logout } = useAuth()
  return (
    <AlfaWidgetProvider
      config={{
        storagePrefix: 'contracts_bot',
        getAuthHeaders,
        onUnauthenticated: () => void logout(),
        // showModelPicker is false for consumers (central admin controls model)
        pageHint: (p) => (p === 'dashboard' ? 'Questions about your SAM results' : 'Ask ALFa'),
      }}
    >
      <AlfaAskAiProvider>
        {/* app routes */}
        <AlfaAskAiDock enabled={!!user} accountLabel={user?.user ?? ''} />
      </AlfaAskAiProvider>
    </AlfaWidgetProvider>
  )
}
```

Register per-page context anywhere inside the provider:

```tsx
import { useAlfaAskAiRegistration } from '@alfa-ai/chat-widget'
useAlfaAskAiRegistration({ page: 'dashboard', playerName: '', context: { /* snapshot */ } })
```

Popup route `/alfa-chat`:

```tsx
import { AlfaChatPopup } from '@alfa-ai/chat-widget'
// render <AlfaChatPopup accountLabel={...} /> at that route (no app chrome)
```

## Config reference (`AlfaWidgetConfig`)

| Field | Default | Purpose |
|---|---|---|
| `getAuthHeaders` | (required) | App auth token resolver |
| `storagePrefix` | `"alfa"` | localStorage namespace |
| `apiBasePath` | `"/api/ai-narrative"` | same-origin models/ask endpoints |
| `avatarSrc` | `/branding/alfa-ai-avatar.png` | avatar web path |
| `brandLabel` | `"ALFa AI"` | header/launcher label |
| `showModelPicker` | `false` | admin-only model dropdown |
| `onUnauthenticated` | - | e.g. logout |
| `pageHint` / `placeholder` / `emptyStateHint` | generic | per-page copy |
| `popupPath` | `"/alfa-chat"` | popup route |

## Build / publish

```bash
npm run build      # tsup -> dist/ (esm + cjs + d.ts)
npm publish --registry http://hub
```

The avatar must also be copied into each consumer's `frontend/public/branding/`
(and `api/static/branding/` if the API serves the SPA). See the runbook.
