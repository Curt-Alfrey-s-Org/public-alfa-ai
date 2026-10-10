import { Link } from "react-router-dom";

import { TerminalPre } from "./InspectionSteps";
import type {
  AppliedSetting,
  HostActionProposal,
  HostActionRecord,
  MissionNavigationHint,
  SettingProposal,
} from "./askAlfaTypes";

const HOST_ACTION_OUTPUT_LIMIT = 12000;

function proposalKindLabel(proposal: HostActionProposal): string {
  if (proposal.action_category === "mission") return "Mission action";
  return "Host action";
}

function resultKindLabel(result: HostActionRecord): string {
  if (result.action_category === "mission") {
    if (result.status === "rejected") return "Mission action rejected";
    if (result.status === "executed") return "Mission queued (see next steps below)";
    return "Mission action failed";
  }
  if (result.status === "rejected") return "Host action rejected";
  if (result.status === "executed") return "Host action completed";
  return "Host action failed";
}

export function HostActionApproveCard({
  proposal,
  messageIndex,
  actionBusy,
  tier2Ack,
  onAck,
  onReview,
}: {
  proposal: HostActionProposal;
  messageIndex: number;
  actionBusy: string | null;
  tier2Ack: Record<string, boolean>;
  onAck: (id: string, checked: boolean) => void;
  onReview: (actionId: string, approve: boolean, messageIndex: number) => void;
}) {
  return (
    <div className="rounded-lg border border-amber-800 bg-amber-950/30 px-3 py-2 text-[11px]">
      <p className="font-medium text-amber-300">
        {proposalKindLabel(proposal)} -- needs your approval
      </p>
      {proposal.action_key && (
        <p className="mt-0.5 text-[10px] uppercase tracking-wide text-slate-500">
          {proposal.action_key}
          {proposal.action_category === "mission"
            ? " (brain API / hub feeder)"
            : proposal.host
              ? ` on host ${proposal.host}`
              : ""}
        </p>
      )}
      <p className="mt-1 text-slate-300">
        Auth level:{" "}
        <span className="font-medium text-amber-200">
          {proposal.auth_level ||
            ((proposal.risk_tier ?? 1) >= 3
              ? "Destructive"
              : (proposal.risk_tier ?? 1) >= 2
                ? "Ops (mutating)"
                : "Read")}
        </span>
      </p>
      {(proposal.will_enable_packs || []).length > 0 && (
        <p className="mt-1 text-sky-300">
          Approve will enable: {(proposal.will_enable_packs || []).join(", ")}
        </p>
      )}
      {(proposal.risk_tier ?? 1) >= 2 && (
        <label className="mt-2 flex items-start gap-2 text-slate-300">
          <input
            type="checkbox"
            checked={!!tier2Ack[proposal.id]}
            onChange={(e) => onAck(proposal.id, e.target.checked)}
            className="mt-0.5"
          />
          <span>I confirm this {proposal.auth_level || "mutating"} action.</span>
        </label>
      )}
      <div className="mt-2 flex gap-2">
        <button
          type="button"
          disabled={actionBusy === proposal.id}
          onClick={() => onReview(proposal.id, true, messageIndex)}
          className="rounded bg-emerald-700 px-2 py-1 text-white hover:bg-emerald-600 disabled:opacity-40"
        >
          {actionBusy === proposal.id ? "Running..." : "Approve"}
        </button>
        <button
          type="button"
          disabled={actionBusy === proposal.id}
          onClick={() => onReview(proposal.id, false, messageIndex)}
          className="rounded border border-slate-600 px-2 py-1 text-slate-300 hover:bg-slate-800 disabled:opacity-40"
        >
          Reject
        </button>
      </div>
      {proposal.summary && (
        <pre className="mt-2 max-h-24 overflow-auto whitespace-pre-wrap break-words text-slate-400">
          {proposal.summary}
        </pre>
      )}
    </div>
  );
}

export function SettingApproveCard({
  proposal,
  messageIndex,
  actionBusy,
  onReview,
}: {
  proposal: SettingProposal;
  messageIndex: number;
  actionBusy: string | null;
  onReview: (proposalId: string, approve: boolean, messageIndex: number) => void;
}) {
  return (
    <div className="rounded-lg border border-amber-800 bg-amber-950/30 px-3 py-2 text-[11px]">
      <p className="font-medium text-amber-300">Proposed policy setting</p>
      <p className="mt-0.5 font-mono text-amber-200/90">{proposal.key}</p>
      {proposal.description && (
        <p className="mt-1 text-slate-400">{proposal.description}</p>
      )}
      <p className="mt-1 text-slate-300">
        {proposal.old_value || "(empty)"} -&gt; {proposal.new_value || "(empty)"}
      </p>
      {proposal.requires_approve_reason && (
        <p className="mt-1 text-amber-400/80">{proposal.requires_approve_reason}</p>
      )}
      <div className="mt-2 flex gap-2">
        <button
          type="button"
          disabled={actionBusy === proposal.id}
          onClick={() => onReview(proposal.id, true, messageIndex)}
          className="rounded bg-emerald-700 px-2 py-1 text-white hover:bg-emerald-600 disabled:opacity-40"
        >
          {actionBusy === proposal.id ? "Applying..." : "Approve"}
        </button>
        <button
          type="button"
          disabled={actionBusy === proposal.id}
          onClick={() => onReview(proposal.id, false, messageIndex)}
          className="rounded border border-slate-600 px-2 py-1 text-slate-300 hover:bg-slate-800 disabled:opacity-40"
        >
          Reject
        </button>
      </div>
    </div>
  );
}

export function MissionNavigationCard({ hint }: { hint: MissionNavigationHint }) {
  return (
    <div className="ml-11 mt-1.5 max-w-[95%] rounded-lg border border-sky-800 bg-sky-950/30 px-3 py-2 text-[11px]">
      <p className="font-medium text-sky-200">Where to see live output</p>
      <p className="mt-1 text-slate-300">{hint.summary}</p>
      <ol className="mt-2 list-decimal space-y-1 pl-4 text-slate-400">
        {hint.steps.map((step) => (
          <li key={step}>{step}</li>
        ))}
      </ol>
      <Link
        to={hint.missions_path}
        className="mt-3 inline-block rounded bg-sky-700 px-3 py-1.5 text-[11px] font-medium text-white hover:bg-sky-600"
      >
        Open Missions (run {hint.run_id.slice(0, 8)}...)
      </Link>
    </div>
  );
}

export function HostActionTerminal({ result }: { result: HostActionRecord }) {
  const command =
    result.command_run?.trim() ||
    (result.action_key && result.host
      ? `${result.action_key} on host ${result.host}`
      : "");
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";
  const exitCode = result.exit_code;
  const hostLabel = result.host ? `host ${result.host}` : "host";
  const stdoutTrimmed = stdout.trim();
  const stderrTrimmed = stderr.trim();
  const stdoutDisplay =
    stdout.length > HOST_ACTION_OUTPUT_LIMIT
      ? `${stdout.slice(0, HOST_ACTION_OUTPUT_LIMIT)}\n... truncated (${stdout.length} chars total)`
      : stdout;
  const statusLine =
    result.status === "rejected"
      ? "Rejected"
      : result.status === "executed"
        ? `${hostLabel} · exit ${exitCode ?? 0}`
        : `${hostLabel} · failed · exit ${exitCode ?? "?"}`;

  return (
    <div className="mt-2 rounded border border-slate-800 bg-slate-950/80 font-mono text-[11px] leading-relaxed">
      <div className="border-b border-slate-800 px-2 py-1 text-slate-500">{statusLine}</div>
      {command && (
        <TerminalPre variant="command" className="max-h-24 overflow-auto border-b border-slate-800">
          $ {command}
        </TerminalPre>
      )}
      <TerminalPre variant="stdout" className="max-h-72 overflow-auto">
        {stdoutTrimmed ? stdoutDisplay : stderrTrimmed ? "" : "(no output)"}
      </TerminalPre>
      {stderrTrimmed && (
        <TerminalPre variant="stderr" className="max-h-40 overflow-auto">
          {stderr.length > HOST_ACTION_OUTPUT_LIMIT
            ? `${stderr.slice(0, HOST_ACTION_OUTPUT_LIMIT)}\n... truncated`
            : stderr}
        </TerminalPre>
      )}
    </div>
  );
}

export function AppliedSettingCard({ setting }: { setting: AppliedSetting }) {
  return (
    <div className="ml-11 mt-1.5 max-w-[85%] rounded-lg border border-emerald-800 bg-emerald-950/40 px-3 py-1.5 text-[11px] text-emerald-400">
      <p className="font-medium text-emerald-300">Applied setting</p>
      <p className="mt-0.5 font-mono text-emerald-400/90">{setting.key}</p>
      {setting.description && (
        <p className="mt-1 text-slate-400">{setting.description}</p>
      )}
      <p className="mt-1 text-emerald-400/80">
        {setting.old_value || "(empty)"} -&gt; {setting.new_value || "(empty)"}
      </p>
      <p className="mt-1 text-slate-500">Logged in AI Actions -&gt; Settings</p>
    </div>
  );
}

export function CursorHandoffCard({
  text,
  copied,
  onCopy,
}: {
  text: string;
  copied: boolean;
  onCopy: () => void;
}) {
  return (
    <div className="ml-11 mt-1.5 max-w-[95%] rounded-lg border border-sky-800 bg-sky-950/25 px-3 py-2 text-[11px]">
      <p className="font-medium text-sky-200">Cursor handoff</p>
      <p className="mt-1 text-slate-400">
        Copy into Composer/Agent after you Approve reproduce (or if reproduce is
        read-only).
      </p>
      <pre className="mt-2 max-h-40 overflow-auto whitespace-pre-wrap rounded border border-slate-800 bg-slate-950/80 px-2 py-1.5 text-[10px] text-slate-300">
        {text}
      </pre>
      <button
        type="button"
        onClick={onCopy}
        className="mt-2 rounded bg-sky-700 px-2 py-1 text-white hover:bg-sky-600"
      >
        {copied ? "Copied" : "Copy for Cursor"}
      </button>
    </div>
  );
}

export function HostActionResultCard({
  result,
  actionBusy,
  auditCopied,
  onCopyAudit,
  onFeedback,
}: {
  result: HostActionRecord;
  actionBusy: string | null;
  auditCopied: boolean;
  onCopyAudit: () => void;
  onFeedback: (helpful: boolean) => void;
}) {
  return (
    <div
      className={`ml-11 mt-1.5 max-w-[95%] rounded-lg border px-3 py-2 text-[11px] ${
        result.status === "executed"
          ? "border-emerald-800 bg-emerald-950/30 text-emerald-300"
          : result.status === "rejected"
            ? "border-slate-700 bg-slate-900 text-slate-400"
            : "border-red-800 bg-red-950/30 text-red-300"
      }`}
    >
      <p className="font-medium">{resultKindLabel(result)}</p>
      {result.action_key && (
        <p className="mt-0.5 text-[10px] uppercase tracking-wide text-slate-500">
          {result.action_key}
        </p>
      )}
      {(result.enabled_packs || []).length > 0 && (
        <p className="mt-1 text-sky-300">
          Enabled packs: {(result.enabled_packs || []).join(", ")}
        </p>
      )}
      {result.status !== "rejected" && <HostActionTerminal result={result} />}
      {result.bot_audit_excerpt && (
        <div className="mt-2 rounded border border-slate-800 bg-slate-950/80 px-2 py-1.5">
          <p className="text-[10px] font-medium text-sky-200">Grok Bot audit excerpt</p>
          <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap text-[10px] text-slate-300">
            {result.bot_audit_excerpt}
          </pre>
          <button
            type="button"
            onClick={onCopyAudit}
            className="mt-2 rounded bg-sky-700 px-2 py-1 text-white hover:bg-sky-600"
          >
            {auditCopied ? "Copied" : "Copy for Grok Bot audit"}
          </button>
        </div>
      )}
      <div className="mt-2 flex gap-2">
        <button
          type="button"
          disabled={actionBusy === result.id}
          onClick={() => onFeedback(true)}
          className="rounded border border-slate-700 px-2 py-0.5 text-slate-400 hover:text-emerald-400"
        >
          Helpful
        </button>
        <button
          type="button"
          disabled={actionBusy === result.id}
          onClick={() => onFeedback(false)}
          className="rounded border border-slate-700 px-2 py-0.5 text-slate-400 hover:text-amber-400"
        >
          Not helpful
        </button>
      </div>
    </div>
  );
}
