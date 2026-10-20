import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import "./index.css";

// After deploys, cached index.html can reference missing chunks — reload once (audit VITE-003).
window.addEventListener("vite:preloadError", () => {
  window.location.reload();
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter basename="/alfa-ai">
      <App />
    </BrowserRouter>
  </StrictMode>,
);
