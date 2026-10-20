/** Client FIFO for Ask ALFa follow-ups while a turn runs (v1). */

export const MAX_QUEUED_TURNS = 8;

export interface QueuedTurn {
  id: string;
  content: string;
}

export function newQueuedTurnId(): string {
  return `q-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function enqueueFollowUp(
  queue: QueuedTurn[],
  content: string,
): { queue: QueuedTurn[]; rejected: null | "empty" | "full" } {
  const trimmed = content.trim();
  if (!trimmed) {
    return { queue, rejected: "empty" };
  }
  if (queue.length >= MAX_QUEUED_TURNS) {
    return { queue, rejected: "full" };
  }
  return {
    queue: [...queue, { id: newQueuedTurnId(), content: trimmed }],
    rejected: null,
  };
}

export function dequeueFollowUp(
  queue: QueuedTurn[],
): { next: QueuedTurn | null; rest: QueuedTurn[] } {
  if (queue.length === 0) {
    return { next: null, rest: queue };
  }
  const [next, ...rest] = queue;
  return { next, rest };
}
