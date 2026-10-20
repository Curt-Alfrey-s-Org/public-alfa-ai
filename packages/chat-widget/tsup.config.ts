import { defineConfig } from 'tsup'

export default defineConfig({
  entry: ['src/index.ts'],
  format: ['esm', 'cjs'],
  dts: true,
  sourcemap: true,
  clean: true,
  treeshake: true,
  external: ['react', 'react-dom'],
  onSuccess: async () => {
    const { copyFileSync, mkdirSync } = await import('node:fs')
    const { dirname, join } = await import('node:path')
    const { fileURLToPath } = await import('node:url')
    const here = dirname(fileURLToPath(import.meta.url))
    mkdirSync(join(here, 'dist'), { recursive: true })
    copyFileSync(join(here, 'src/styles.css'), join(here, 'dist/styles.css'))
  },
})
