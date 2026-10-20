import { useState } from "react";

export interface ContextCategoryUsage {
  key: string;
  label: string;
  tokens: number;
}

export interface ContextUsage {
  used_tokens: number;
  window_tokens: number;
  source: "char_estimate" | "litellm_usage";
  categories: ContextCategoryUsage[];
  completion_tokens?: number;
}

function formatTokenCount(value: number): string {
  if (value >= 10000) {
    const k = value / 1000;
    return `${k >= 10 ? Math.round(k) : k.toFixed(1)}k`;
  }
  if (value >= 1000) {
    return `${(value / 1000).toFixed(1)}k`;
  }
  return String(value);
}

function usagePercent(used: number, window: number): number {
  if (window <= 0) return 0;
  return Math.min(100, Math.round((used / window) * 100));
}

interface Props {
  usage: ContextUsage | null;
}

export default function ContextUsageRing({ usage }: Props) {
  const [open, setOpen] = useState(false);

  if (!usage || usage.window_tokens <= 0) {
    return null;
  }

  const percent = usagePercent(usage.used_tokens, usage.window_tokens);
  const radius = 14;
  const stroke = 3;
  const normalizedRadius = radius - stroke / 2;
  const circumference = 2 * Math.PI * normalizedRadius;
  const offset = circumference - (percent / 100) * circumference;
  const title = `Context ${percent}% · ${formatTokenCount(usage.used_tokens)} / ${formatTokenCount(usage.window_tokens)}`;

  return (
    <div className="relative shrink-0 self-end pb-1">
      <button
        type="button"
        onClick={() => setOpen((value) => !value)}
        className="flex h-11 w-11 items-center justify-center rounded-xl border border-slate-700 bg-slate-800/80 text-slate-300 hover:border-sky-600 hover:text-sky-300"
        title={title}
        aria-label={title}
        aria-expanded={open}
      >
        <svg width="32" height="32" viewBox="0 0 32 32" className="-rotate-90">
          <circle
            cx="16"
            cy="16"
            r={normalizedRadius}
            fill="none"
            stroke="currentColor"
            strokeWidth={stroke}
            className="text-slate-700"
          />
          <circle
            cx="16"
            cy="16"
            r={normalizedRadius}
            fill="none"
            stroke="currentColor"
            strokeWidth={stroke}
            strokeDasharray={`${circumference} ${circumference}`}
            strokeDashoffset={offset}
            strokeLinecap="round"
            className="text-sky-500 transition-[stroke-dashoffset] duration-300"
          />
        </svg>
        <span className="pointer-events-none absolute text-[9px] font-medium tabular-nums text-slate-200">
          {percent}%
        </span>
      </button>
      {open && (
        <div
          className="absolute bottom-full left-0 z-20 mb-2 w-52 rounded-lg border border-slate-700 bg-slate-900/95 px-3 py-2 text-[11px] shadow-xl"
          role="region"
          aria-label="Context usage breakdown"
        >
          <p className="font-medium text-slate-200">{title}</p>
          <p className="mt-0.5 text-[10px] text-slate-500">
            {usage.source === "litellm_usage" ? "LiteLLM prompt tokens" : "Character estimate"}
          </p>
          <ul className="mt-2 space-y-1">
            {usage.categories.map((category) => (
              <li
                key={category.key}
                className="flex items-center justify-between gap-2 text-slate-400"
              >
                <span>{category.label}</span>
                <span className="tabular-nums text-slate-300">
                  {formatTokenCount(category.tokens)}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
