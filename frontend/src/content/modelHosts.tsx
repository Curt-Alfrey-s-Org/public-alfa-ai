/** Customer-facing model tiers (no internal host topology). SSoT: deploy/litellm_config.yaml */
export const modelTiers = [
  {
    rank: 1,
    alias: "frontier-code",
    model: "Qwen3.8 27B (production)",
    summary: "Best for complex code, refactors, and system design.",
  },
  {
    rank: 2,
    alias: "fast / chat",
    model: "Qwen3.8 27B",
    summary: "Default everyday chat and short coding help. Fast and capable.",
  },
  {
    rank: 3,
    alias: "embed",
    model: "Qwen3-Embedding 4B",
    summary: "Search and document embeddings (not a chat model).",
  },
] as const;

export function ModelTierList() {
  return (
    <ol className="mt-3 space-y-3 text-sm leading-relaxed text-slate-400">
      {modelTiers.map((row) => (
        <li key={row.alias} className="flex gap-3">
          <span className="flex h-6 w-6 flex-shrink-0 items-center justify-center rounded-full bg-slate-800 text-xs font-medium text-slate-300">
            {row.rank}
          </span>
          <div>
            <span className="font-medium text-slate-300">{row.alias}</span>
            <span className="text-slate-500"> ({row.model})</span>
            <p className="mt-0.5">{row.summary}</p>
          </div>
        </li>
      ))}
    </ol>
  );
}
