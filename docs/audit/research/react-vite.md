# React + Vite (SPA pattern)

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **React docs:** https://react.dev
- **React reference:** https://react.dev/reference/react
- **React versions / upgrade guide:** https://react.dev/versions
- **React releases:** https://github.com/facebook/react/releases
- **Rules of React:** https://react.dev/reference/rules
- **React Compiler docs:** https://react.dev/reference/react-compiler/configuration
- **Vite docs:** https://vite.dev (note: `vitejs.dev` aliases to `vite.dev`)
- **Vite build guide:** https://vite.dev/guide/build.html
- **Vite static deploy:** https://vite.dev/guide/static-deploy
- **Vite releases:** https://vite.dev/releases (also https://github.com/vitejs/vite/releases)
- **Vite changelog:** https://github.com/vitejs/vite/blob/main/packages/vite/CHANGELOG.md

## Current stable / supported version (as of 2026-05-13)

- **React latest stable:** `19.2.6` (released 2026-05-06). Source: https://www.npmjs.com/package/react and https://github.com/facebook/react/releases.
- **React 19.2** introduced `Activity` component, `useEffectEvent` hook, React Compiler 1.0 (released 2025-10-07). Source: https://react.dev/blog/2025/10/01/react-19-2 and https://react.dev/versions.
- **Vite latest stable:** `8.0.12` (released 2026-05-11). Source: https://www.npmjs.com/package/vite and https://vite.dev/releases.
- **Vite support windows:** 8.0.x receives regular patch releases; 7.3.x receives important fixes + security; 6.4.x receives security patches only. Anything < 6.4 is EOL. Source: https://vite.dev/releases.
- **Bundler:** Vite 8 ships **Rolldown 1.0.0** as its bundler (replacing Rollup as the build-time bundler). Source: https://vite.dev/releases and https://rolldown.rs.

## Key official best practices

- **Browser baseline:** Vite's default production targets are Chrome ≥111, Edge ≥111, Firefox ≥114, Safari ≥16.4 (the "Baseline Widely Available" set). Lower targets require `build.target=es2015` minimum and are limited by native ESM dynamic-import support (Chrome 64+, Firefox 67+, Safari 11.1+, Edge 79+). Source: https://vite.dev/guide/build.html ("Browser Compatibility").
- **Polyfills:** Vite handles syntax transforms only; polyfills require `@vitejs/plugin-legacy` for legacy chunks, or a polyfill CDN. Source: same page.
- **Public base path:** for non-root deploys, set `base` in `vite.config.js` (or pass `vite build --base=/my/path/`). Asset URLs in `.html`, JS imports, CSS `url()` are all rewritten. For dynamic concatenation use `import.meta.env.BASE_URL`. Source: https://vite.dev/guide/build.html ("Public Base Path").
- **Cache busting / preload-error handling:** when a deploy invalidates assets, old clients hit `vite:preloadError`. Listen for this event and `window.location.reload()`. Crucially: set `Cache-Control: no-cache` on `index.html` so users always fetch fresh asset references. Source: https://vite.dev/guide/build.html ("Load Error Handling").
- **MPA:** Vite supports multi-page builds via `rolldownOptions.input` mapping each `.html` entry. Source: https://vite.dev/guide/build.html ("Multi-Page App").
- **Library mode:** `build.lib` switches to library output (ESM + UMD/CJS). Externalize peer deps. Source: https://vite.dev/guide/build.html ("Library Mode").
- **Rolldown options:** advanced build customization via `build.rolldownOptions`. Source: https://rolldown.rs/reference/.
- **React Compiler (opt-in optimization):** React 19+'s Compiler memoizes components automatically. Enable via the Babel plugin in `vite.config.js`. Source: https://react.dev/reference/react-compiler/configuration.
- **Strict Mode in dev:** `<StrictMode>` causes double-invocation of effects in development to surface side-effect bugs — **don't disable it** in dev to silence "duplicate API calls". Source: https://react.dev/reference/react/StrictMode.
- **Rules of React:** components and hooks must be pure; React calls them; hooks only at top level / from React components or other hooks. Source: https://react.dev/reference/rules.
- **Production build:** `vite build` produces a static SPA in `dist/`. Serve via any static host (nginx `try_files`, Caddy, Cloudflare Pages, etc.). Source: https://vite.dev/guide/static-deploy.

## Canonical configuration examples

**Minimal `vite.config.js` for a React SPA** (matches https://vite.dev/guide/build.html):

```js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  base: '/',                // change for sub-path deploys
  build: {
    target: 'es2020',
    sourcemap: true,
  },
  server: {
    proxy: {
      '/api': 'http://localhost:8420',  // proxy to backend in dev
    },
  },
})
```

**nginx `try_files` block for an SPA** (canonical from https://vite.dev/guide/static-deploy):

```nginx
server {
    listen 80;
    server_name app.example.com;
    root /usr/share/nginx/html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Hash-named asset bundles can be cached aggressively:
    location ~* \.(js|css|woff2|svg|png|jpg|webp)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # index.html must NOT be cached, per Vite's load-error guidance:
    location = /index.html {
        add_header Cache-Control "no-cache";
    }
}
```

Source: https://vite.dev/guide/static-deploy and https://vite.dev/guide/build.html ("Load Error Handling").

**React Strict Mode entry point** (verbatim from https://react.dev/reference/react/StrictMode):

```jsx
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>
)
```

## Common pitfalls / gotchas

- **Old Vite < 6.4 is EOL** (no security patches). Source: https://vite.dev/releases.
- **`index.html` cached by intermediaries** breaks deploys — old clients reference deleted hashed bundles → `vite:preloadError`. Always set `Cache-Control: no-cache` on `index.html`. Source: https://vite.dev/guide/build.html.
- **Rolldown is the bundler in Vite 8.x** — older `rollupOptions` keys are renamed to `rolldownOptions`. Source: https://vite.dev/releases (Vite 8 changelog).
- **`react-router` SPA fallback** requires `try_files $uri /index.html` server-side or every deep link 404s. Source: https://vite.dev/guide/static-deploy.
- **`React.StrictMode` double-renders effects** in development only — production runs once. Don't write code that depends on single-invocation in dev. Source: https://react.dev/reference/react/StrictMode.
- **Pre-existing `process.env.*` in app code** is not statically replaced; only `import.meta.env.*`. Source: https://vite.dev/guide/env-and-mode.
- **Dev-server CORS:** `server.proxy` is the official escape hatch for talking to a same-origin API in dev. Configuring CORS server-side just for dev is a code smell. Source: https://vite.dev/config/server-options.

## Authoritative URLs to cite in our docs

- https://react.dev
- https://react.dev/versions
- https://react.dev/reference/react
- https://react.dev/reference/rules
- https://react.dev/reference/react/StrictMode
- https://github.com/facebook/react/releases
- https://vite.dev
- https://vite.dev/guide/build.html
- https://vite.dev/guide/static-deploy
- https://vite.dev/guide/env-and-mode
- https://vite.dev/releases
- https://github.com/vitejs/vite/blob/main/packages/vite/CHANGELOG.md

## AUDIT CHECKLIST for the Audit Agent

1. **React version:** confirm `package.json` of every React app in the repo (chat UI on `hub`/`apps`, plus any bot frontends linked from `AGENTS.md`) pins a React 19.x version compatible with upstream support window. Flag any React <18 (deprecated React DOM `render` API).
2. **Vite version:** confirm Vite ≥ 7.3 in every SPA's `package.json` (security floor). Flag any Vite < 6.4 as EOL.
3. **`base:` configuration:** if the chat SPA is served at a sub-path through nginx (e.g. `/chat/`), confirm `vite.config.{js,ts}` `base:` matches the nginx location prefix. Mismatch breaks asset URLs in production.
4. **`Cache-Control: no-cache` on `index.html`:** verify the nginx config that serves the SPA has an explicit `location = /index.html` (or equivalent) with `Cache-Control: no-cache`. Without this, deploys cause `vite:preloadError` on returning users. Path: `deploy/nginx.conf` (or per-app nginx).
5. **`vite:preloadError` listener:** grep the SPA entry (`src/main.{ts,tsx,js,jsx}`) for `vite:preloadError` — its absence is a real (silent) UX regression on every deploy.
6. **SPA fallback:** confirm `try_files $uri $uri/ /index.html` is in the nginx config for the SPA root. Path: `deploy/nginx.conf` and any site-specific nginx config.
7. **Strict Mode:** confirm `<StrictMode>` wraps the root render in production code, not just dev. Path: `src/main.{ts,tsx}`.
8. **React Compiler:** if the team has opted in to React Compiler 1.0, verify the Babel plugin is registered in `vite.config.js` and ESLint v10 is set up per https://react.dev/reference/react-compiler/configuration. If not opted in, document the decision.
9. **Bundler keys:** if upgrading to Vite 8.x, search the codebase for `rollupOptions:` and confirm whether to migrate to `rolldownOptions:` per https://vite.dev/releases.
10. **`process.env` vs `import.meta.env`:** grep for `process.env.` in client-side React code. Vite does NOT replace these by default. Source: https://vite.dev/guide/env-and-mode.
11. **Browser target:** confirm `build.target` aligns with the customer browser baseline. Default Vite 8 targets imply Safari ≥ 16.4 — if the user base includes older iPhones, `build.target` must be lowered (and `@vitejs/plugin-legacy` added).
12. **Static asset cache headers:** confirm hashed bundles get `Cache-Control: public, immutable, max-age=31536000` while `index.html` is `no-cache`. Path: `deploy/nginx.conf`.
