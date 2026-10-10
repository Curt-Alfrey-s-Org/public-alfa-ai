import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/alfa-ai/",
  server: {
    proxy: {
      "/alfa-ai/api": {
        target: "http://127.0.0.1:8412",
        changeOrigin: true,
      },
    },
  },
});
