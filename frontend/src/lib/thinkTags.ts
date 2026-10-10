/**
 * Reasoning models (Qwen hybrid "thinking"/precise mode) emit raw <think>...</think>
 * blocks inline in message content. Split that out so the UI can show a friendly
 * "thinking" indicator instead of the literal tag text while it streams in.
 */

export interface ThinkSplit {
  /** True while an opening <think> tag has streamed in but no closing tag yet. */
  thinking: boolean;
  /** Content to actually render (post-</think>, or pre-<think> if none started yet). */
  visible: string;
}

const OPEN_TAG = "<think>";
const CLOSE_TAG = "</think>";

export function splitThinkContent(raw: string): ThinkSplit {
  if (!raw) return { thinking: false, visible: "" };

  const closeIdx = raw.lastIndexOf(CLOSE_TAG);
  if (closeIdx !== -1) {
    return { thinking: false, visible: raw.slice(closeIdx + CLOSE_TAG.length) };
  }

  const openIdx = raw.indexOf(OPEN_TAG);
  if (openIdx !== -1) {
    return { thinking: true, visible: raw.slice(0, openIdx) };
  }

  return { thinking: false, visible: raw };
}
