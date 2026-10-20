export interface DumpDecision {
  entity_id: string;
  action: "on" | "off" | "skip" | string;
  reason: string;
}

export interface DumpMeta {
  thinking?: string[];
  missing_entity_ids?: string[];
  solar_w?: number | null;
  load_w?: number | null;
  effective_load_w?: number | null;
  surplus_w?: number | null;
  surplus_after_path_losses_w?: number | null;
  combined_path_losses_w?: number | null;
  charge_state?: string;
  soc_gate?: string;
  skipped?: string;
  [key: string]: unknown;
}

export interface DumpLastTick {
  ok: boolean;
  error?: string;
  decisions?: DumpDecision[];
  meta?: DumpMeta;
  recorded_at?: string;
}

export interface DumpStatusResponse {
  ok: boolean;
  ha_ready: boolean;
  dump_enabled: boolean;
  auto_actuate: boolean;
  interval_seconds: number;
  recorded_at: string | null;
  last: DumpLastTick | null;
}

const SOLAR_DUMP_TYPES = new Set([
  "solar_dump_observed",
  "solar_dump_recommended",
  "solar_dump_actuated",
]);

export function isSolarDumpAction(actionType: string): boolean {
  return SOLAR_DUMP_TYPES.has(actionType);
}

function timeAgo(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

function formatWatts(value: unknown): string {
  if (value === null || value === undefined) return "-";
  if (typeof value === "number" && Number.isFinite(value)) return `${Math.round(value)} W`;
  return String(value);
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string");
}

function asDecisions(value: unknown): DumpDecision[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is Record<string, unknown> => item !== null && typeof item === "object")
    .map((item) => ({
      entity_id: String(item.entity_id ?? ""),
      action: String(item.action ?? "skip"),
      reason: String(item.reason ?? ""),
    }))
    .filter((d) => d.entity_id);
}

function asMeta(value: unknown): DumpMeta | null {
  if (value === null || typeof value !== "object") return null;
  return value as DumpMeta;
}

export function extractDumpPayload(detail: Record<string, unknown>): {
  ok: boolean | null;
  error: string | null;
  meta: DumpMeta | null;
  decisions: DumpDecision[];
} {
  const ok = typeof detail.ok === "boolean" ? detail.ok : null;
  const error =
    typeof detail.error === "string"
      ? detail.error
      : typeof detail.skipped === "string"
        ? detail.skipped
        : null;
  const meta = asMeta(detail.meta) ?? (detail.thinking || detail.surplus_w !== undefined ? asMeta(detail) : null);

  let decisions = asDecisions(detail.decisions);
  if (decisions.length === 0 && typeof detail.entity_id === "string") {
    decisions = [
      {
        entity_id: detail.entity_id,
        action: String(detail.action ?? "skip"),
        reason: String(detail.reason ?? ""),
      },
    ];
  }

  return { ok, error, meta, decisions };
}

function actionBadgeClass(action: string): string {
  switch (action) {
    case "on":
      return "border-emerald-800 text-emerald-400";
    case "off":
      return "border-slate-700 text-slate-400";
    case "skip":
      return "border-amber-800 text-amber-400";
    default:
      return "border-violet-800 text-violet-400";
  }
}

function StatusPill({ label, ok }: { label: string; ok: boolean }) {
  return (
    <span
      className={`rounded border px-2 py-0.5 text-[10px] uppercase tracking-wide ${
        ok ? "border-emerald-800 text-emerald-400" : "border-amber-800 text-amber-400"
      }`}
    >
      {label}: {ok ? "yes" : "no"}
    </span>
  );
}

export function DumpDecisionsTable({ decisions }: { decisions: DumpDecision[] }) {
  if (decisions.length === 0) {
    return <p className="text-xs text-slate-500">No switch decisions this tick.</p>;
  }
  return (
    <div className="overflow-x-auto rounded border border-slate-800">
      <table className="w-full text-left text-xs">
        <thead>
          <tr className="border-b border-slate-800 bg-slate-950/60 text-[10px] uppercase tracking-wide text-slate-500">
            <th className="px-3 py-2 font-medium">Entity</th>
            <th className="px-3 py-2 font-medium">Action</th>
            <th className="px-3 py-2 font-medium">Reason</th>
          </tr>
        </thead>
        <tbody>
          {decisions.map((row) => (
            <tr key={row.entity_id} className="border-b border-slate-800/80 last:border-0">
              <td className="px-3 py-2 font-mono text-slate-300">{row.entity_id}</td>
              <td className="px-3 py-2">
                <span
                  className={`rounded border px-1.5 py-0.5 text-[10px] uppercase ${actionBadgeClass(row.action)}`}
                >
                  {row.action}
                </span>
              </td>
              <td className="px-3 py-2 text-slate-400">{row.reason || "-"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function DumpThinkingList({ thinking }: { thinking: string[] }) {
  if (thinking.length === 0) {
    return <p className="text-xs text-slate-500">No thinking lines recorded.</p>;
  }
  return (
    <ol className="list-decimal space-y-1 pl-5 text-xs text-slate-300">
      {thinking.map((line, index) => (
        <li key={`${index}-${line.slice(0, 24)}`} className="leading-relaxed">
          {line}
        </li>
      ))}
    </ol>
  );
}

function MetaGrid({ meta }: { meta: DumpMeta }) {
  const missing = asStringArray(meta.missing_entity_ids);
  const rows: { label: string; value: string }[] = [
    { label: "Solar", value: formatWatts(meta.solar_w) },
    { label: "Effective load", value: formatWatts(meta.effective_load_w) },
    { label: "Surplus", value: formatWatts(meta.surplus_w) },
    { label: "Surplus after path losses", value: formatWatts(meta.surplus_after_path_losses_w) },
    { label: "Combined path losses", value: formatWatts(meta.combined_path_losses_w) },
    { label: "Charge state", value: meta.charge_state ? String(meta.charge_state) : "-" },
    { label: "SOC gate", value: meta.soc_gate ? String(meta.soc_gate) : "-" },
    { label: "Skipped", value: meta.skipped ? String(meta.skipped) : "-" },
  ];

  return (
    <div className="space-y-3">
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        {rows.map((row) => (
          <div key={row.label} className="rounded border border-slate-800 bg-slate-950/40 px-3 py-2">
            <p className="text-[10px] uppercase tracking-wide text-slate-600">{row.label}</p>
            <p className="mt-0.5 font-mono text-xs text-slate-200">{row.value}</p>
          </div>
        ))}
      </div>
      {missing.length > 0 && (
        <div className="rounded border border-amber-900/50 bg-amber-950/20 px-3 py-2">
          <p className="text-[10px] uppercase tracking-wide text-amber-500">Missing entity ids</p>
          <p className="mt-1 font-mono text-xs text-amber-200/90">{missing.join(", ")}</p>
        </div>
      )}
    </div>
  );
}

export function DumpStructuredDetail({
  detail,
  actionType,
}: {
  detail: Record<string, unknown>;
  actionType?: string;
}) {
  const { ok, error, meta, decisions } = extractDumpPayload(detail);
  const thinking = asStringArray(meta?.thinking);

  return (
    <div className="space-y-4">
      {(ok === false || error) && (
        <p className="rounded border border-red-900/50 bg-red-950/20 px-3 py-2 text-xs text-red-300">
          {error ?? "Tick failed"}
        </p>
      )}
      {actionType === "solar_dump_recommended" && (
        <p className="text-xs text-amber-400">
          Brain does not toggle plugs; Home Assistant automations own on/off. This row is a comparison recommendation.
        </p>
      )}
      {meta && <MetaGrid meta={meta} />}
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Thinking</h4>
        <DumpThinkingList thinking={thinking} />
      </div>
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Decisions</h4>
        <DumpDecisionsTable decisions={decisions} />
      </div>
    </div>
  );
}

export function DumpLastTickPanel({
  status,
}: {
  status: DumpStatusResponse | null;
}) {
  if (!status) {
    return (
      <div className="sticky top-0 z-10 border-b border-slate-800 bg-slate-950/95 px-4 py-3 backdrop-blur">
        <p className="text-xs text-slate-500">Loading last tick...</p>
      </div>
    );
  }

  const last = status.last;
  const meta = last?.meta ?? null;
  const recordedAt = status.recorded_at ?? last?.recorded_at ?? null;
  const thinking = asStringArray(meta?.thinking);
  const decisions = asDecisions(last?.decisions);

  return (
    <div className="sticky top-0 z-10 border-b border-slate-800 bg-slate-950/95 px-4 py-3 backdrop-blur">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-slate-200">Last tick</h3>
        <div className="flex flex-wrap items-center gap-2">
          <StatusPill label="HA ready" ok={status.ha_ready} />
          <StatusPill label="Dump enabled" ok={status.dump_enabled} />
          <StatusPill label="Observe only" ok={!status.auto_actuate} />
          <span className="rounded border border-slate-700 px-2 py-0.5 text-[10px] text-slate-400">
            Ticker: {status.interval_seconds}s
          </span>
          {recordedAt && (
            <span className="text-[10px] text-slate-600">Recorded {timeAgo(recordedAt)}</span>
          )}
        </div>
      </div>

      {!last ? (
        <p className="text-xs text-slate-500">No dump tick recorded yet (wait for ticker or run ha_dump_tick).</p>
      ) : (
        <div className="space-y-4">
          {last.ok === false && (
            <p className="rounded border border-red-900/50 bg-red-950/20 px-3 py-2 text-xs text-red-300">
              {last.error ?? "Last tick failed"}
            </p>
          )}
          {meta && <MetaGrid meta={meta} />}
          <div className="grid gap-4 lg:grid-cols-2">
            <div>
              <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Thinking</h4>
              <DumpThinkingList thinking={thinking} />
            </div>
            <div>
              <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Decisions</h4>
              <DumpDecisionsTable decisions={decisions} />
            </div>
          </div>
        </div>
      )}
      {/* UI poll only; server ticker uses ha_interval_seconds (see HOME_ASSISTANT_BRAIN_INTEGRATION.md Audit). */}
    </div>
  );
}
