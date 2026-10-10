import { useEffect, useState } from "react";

interface Props {
  /** Admin-editable cycle phrases (Settings tab -> chat_thinking_label). Empty = show nothing. */
  phrases: string[];
  intervalMs?: number;
}

/** Cycles through admin-configured phrases while the model is "thinking" (inside <think>). */
export default function ThinkingIndicator({ phrases, intervalMs = 900 }: Props) {
  const [index, setIndex] = useState(0);

  useEffect(() => {
    if (phrases.length <= 1) return;
    const id = setInterval(() => {
      setIndex((i) => (i + 1) % phrases.length);
    }, intervalMs);
    return () => clearInterval(id);
  }, [phrases, intervalMs]);

  if (phrases.length === 0) return null;

  return (
    <span className="animate-pulse text-sm italic text-slate-400">
      {phrases[index % phrases.length]}
    </span>
  );
}
