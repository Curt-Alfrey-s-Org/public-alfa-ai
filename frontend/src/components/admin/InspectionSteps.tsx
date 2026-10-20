import type { ReactNode } from "react";

export interface InspectionStep {
  action_key: string;
  host: string;
  command_run: string;
  stdout: string;
  stderr: string;
  exit_code: number;
  ok: boolean;
  duration_ms: number;
}

export interface ReadinessBlock {
  host: string;
  reason: string;
  fix_steps: string[];
}

/** Terminal-styled pre block (shared with HostActionTerminal styling). */
export function TerminalPre({
  children,
  variant = "stdout",
  className = "max-h-48 overflow-auto",
}: {
  children: ReactNode;
  variant?: "stdout" | "stderr" | "command";
  className?: string;
}) {
  const base = "whitespace-pre-wrap font-mono text-[11px] leading-relaxed";
  if (variant === "stderr") {
    return (
      <pre
        className={`${className} border-t border-slate-800 px-2 py-1.5 ${base} text-red-400/90`}
      >
        {children}
      </pre>
    );
  }
  if (variant === "command") {
    return (
      <pre
        className={`${className} px-2 py-1.5 ${base} text-sky-300/90`}
      >
        {children}
      </pre>
    );
  }
  return (
    <pre className={`${className} px-2 py-1.5 ${base} text-slate-300`}>
      {children}
    </pre>
  );
}

function looksLikeCommand(step: string): boolean {
  const t = step.trim();
  if (!t) return false;
  if (/^(sudo|cd|docker|bash)\b/.test(t)) return true;
  return t.includes(" && ");
}

function distinctHosts(steps: InspectionStep[]): string {
  return [...new Set(steps.map((s) => s.host))].join(", ");
}

export function LiveInspectionLines({ steps }: { steps: InspectionStep[] }) {
  if (steps.length === 0) return null;
  return (
    <div className="flex flex-col gap-0.5">
      {steps.map((step, idx) => (
        <span key={`${step.host}-${step.action_key}-${idx}`} className="text-xs text-slate-400">
          Inspecting host {step.host}: {step.action_key} (
          {step.exit_code === 0 ? "ok" : `exit ${step.exit_code}`})
        </span>
      ))}
    </div>
  );
}

export function InspectionStepsBlock({ inspections }: { inspections: InspectionStep[] }) {
  if (inspections.length === 0) return null;
  const hosts = distinctHosts(inspections);
  const defaultOpen = inspections.length <= 3;

  return (
    <div className="ml-11 mt-1.5 max-w-[95%]">
      <details
        open={defaultOpen}
        className="rounded-lg border border-slate-700 bg-slate-950/60 text-[11px]"
      >
        <summary className="cursor-pointer select-none px-3 py-2 font-medium text-slate-300 hover:text-sky-300">
          Inspected ({inspections.length} steps, {hosts})
        </summary>
        <div className="border-t border-slate-800 px-2 py-2 space-y-2">
          {inspections.map((step, idx) => (
            <details
              key={`${step.host}-${step.action_key}-${idx}`}
              className="rounded border border-slate-800 bg-slate-950/80"
            >
              <summary className="cursor-pointer select-none px-2 py-1.5 text-slate-400 hover:text-slate-200">
                {step.action_key} on host {step.host} -- exit {step.exit_code} --{" "}
                {step.duration_ms} ms
              </summary>
              <div className="border-t border-slate-800 font-mono">
                {step.command_run && (
                  <TerminalPre variant="command" className="max-h-24 overflow-auto">
                    $ {step.command_run}
                  </TerminalPre>
                )}
                <TerminalPre variant="stdout">
                  {step.stdout?.trim() ? step.stdout : "(no stdout)"}
                </TerminalPre>
                {step.stderr?.trim() && (
                  <TerminalPre variant="stderr">
                    {step.stderr}
                  </TerminalPre>
                )}
              </div>
            </details>
          ))}
        </div>
      </details>
    </div>
  );
}

export function ReadinessBlockCard({ block }: { block: ReadinessBlock }) {
  return (
    <div className="ml-11 mt-1.5 max-w-[95%] rounded-lg border border-amber-700 bg-amber-950/40 px-3 py-2 text-[11px]">
      <p className="font-medium text-amber-300">Cannot inspect host {block.host}</p>
      <p className="mt-1 text-slate-300">{block.reason}</p>
      {block.fix_steps.length > 0 && (
        <ol className="mt-2 list-decimal space-y-1.5 pl-4 text-slate-400">
          {block.fix_steps.map((step) => (
            <li key={step}>
              {looksLikeCommand(step) ? (
                <code className="block whitespace-pre-wrap rounded bg-slate-950/80 px-1.5 py-0.5 font-mono text-[10px] text-amber-200/90">
                  {step}
                </code>
              ) : (
                step
              )}
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}
