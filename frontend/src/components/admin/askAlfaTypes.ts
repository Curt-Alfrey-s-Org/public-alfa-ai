import type { ChatTimingMeta } from "../ChatMessage";
import type { QueuedTurn } from "../../lib/askAlfaTurnQueue";
import type { InspectionStep, ReadinessBlock } from "./InspectionSteps";
import type { ContextUsage } from "./ContextUsageRing";

export interface HostActionProposal {
  id: string;
  summary: string;
  status: string;
  action_key?: string;
  action_category?: string;
  host?: string;
  risk_tier?: number;
  auth_level?: string;
  requires_ack?: boolean;
  soft_disabled?: boolean;
  will_enable_packs?: string[];
  pack_label?: string | null;
  enabled_packs?: string[];
}

export interface SettingProposal {
  id: string;
  key: string;
  old_value: string;
  new_value: string;
  status: string;
  description?: string;
  requires_approve_reason?: string;
}

export interface AppliedSetting {
  key: string;
  old_value: string;
  new_value: string;
  description?: string;
}

export interface HostActionRecord extends HostActionProposal {
  action_key?: string;
  host?: string;
  stdout?: string | null;
  stderr?: string | null;
  exit_code?: number | null;
  command_run?: string | null;
  bot_audit_excerpt?: string | null;
}

export interface MissionNavigationHint {
  run_id: string;
  target_host: string;
  target_label?: string;
  skill?: string;
  missions_path: string;
  summary: string;
  steps: string[];
}

export interface AgentMessage {
  role: "user" | "assistant";
  content: string;
  queued?: boolean;
  queueId?: string;
  timing?: ChatTimingMeta;
  appliedSetting?: AppliedSetting | null;
  pendingSettingProposal?: SettingProposal | null;
  hostActionProposal?: HostActionProposal | null;
  hostActionResult?: HostActionRecord | null;
  navigationHint?: MissionNavigationHint | null;
  cursorHandoff?: string | null;
  inspections?: InspectionStep[];
  readinessBlock?: ReadinessBlock | null;
}

export interface ChatSession {
  id: string;
  title: string;
  messages: AgentMessage[];
  pendingQueue: QueuedTurn[];
  busy: boolean;
  busyStartedAt: number | null;
  streamHint: string | null;
  liveInspections: InspectionStep[];
}

export interface HistoryTurn {
  role: "user" | "assistant";
  content: string;
}

export interface MonitoringAgentResponse {
  reply: string;
  applied_setting: AppliedSetting | null;
  pending_setting_proposal: SettingProposal | null;
  host_action_proposal: HostActionProposal | null;
  cursor_handoff?: string | null;
  inspections?: InspectionStep[];
  readiness_block?: ReadinessBlock | null;
  context_usage?: ContextUsage | null;
}
