# Ask ALFa: queued posts while a turn runs

**Ask ALFa only.** Guest chat, signed-in brain chat, and consumer docks stay
one-request-at-a-time. Missions live tool SSE stays on the Missions tab.

## Goal

Match Cursor's chat habit: the operator can **post follow-ups while a turn is
still running**. Those posts appear in the thread immediately and run **FIFO**
after the current turn finishes (success, error, or Stop).

Official references (RULE #1):

- Cursor Cloud Agents **Stream A Run** event types (`status`, `assistant`,
  `tool_call`, `heartbeat`, `result`, `done`) and `Last-Event-ID` resume:
  https://cursor.com/docs/cloud-agent/api/endpoints
- FastAPI `StreamingResponse` (`text/event-stream`):
  https://fastapi.tiangolo.com/advanced/custom-response/#streamingresponse
- MDN `EventSource` / `Last-Event-ID`:
  https://developer.mozilla.org/docs/Web/API/EventSource
- MDN `AbortController` (Stop / close busy tab):
  https://developer.mozilla.org/docs/Web/API/AbortController
- OpenAI Chat Completions streaming (`stream=true`, `delta.content`):
  https://developers.openai.com/api/docs/guides/streaming-responses

## v1 (this change)

Client FIFO on the Ask ALFa dock (`AskAlfaWidget.tsx`):

| Rule | Detail |
|------|--------|
| Send while busy | Composer stays enabled. New user bubbles show in the thread with a **Queued** mark |
| Drain | After the in-flight `/monitoring-agent/stream` ends, the next queued text is POSTed automatically |
| Cap | Max **8** queued follow-ups per session (`MAX_QUEUED_TURNS`) |
| Concurrent LLM | Still **one stream per session**. Soft cap of **3** busy **sessions** is unchanged |
| Stop | Cancels the current fetch only. Remaining queued posts still drain |
| Close tab | Abort then drop that session (queue dies with the tab) |
| Refresh | `sessionStorage` reload clears `busy` and **drops** queued (never sent) bubbles |
| Oversight | Unchanged: mutate still pending until Approve ([ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md)) |

Server path is still one `POST /alfa-ai/api/admin/monitoring-agent/stream` per
drained turn. Body: `message` plus optional `history` (prior dock turns).
No new Postgres `chat_runs` table in v1.

Follow-up phrases such as "yes, show me all that", "audit your answer",
"is it correct?", and "are you sure?" work because the previous assistant
`reply` is resent in `history` ([Conversation state](https://developers.openai.com/api/docs/guides/conversation-state)).
When last turn was a **program rollup**, Ask ALFa re-runs that formatter
(no LLM) and keeps the same `last ~Nh` for activity.
When last turn was **model judgment** and the operator asks to verify,
Ask ALFa emits a packed-store **fact check** instead of asking frontier-code
to grade itself (the model cannot see untruncated `missions_fleet` if the
JSON slice hit the 8000-char cap).
Unmatched follow-ups use resent `history` on
the LLM path. Activity and cluster-status questions still hit the
**deterministic** router when the operator message text matches directly.

## Not in v1

- Server-side turn queue / `chat_runs` persistence
- Cursor-shaped `assistant` token deltas on Ask ALFa (reply still arrives in SSE `done`)
- Merging Missions `tool_call` events into the Ask ALFa timeline
- Guest / consumer / signed-in brain chat queues
- WebSockets

Those stay future work; reuse `mission_event_bus` + Cursor event names when they land.

## UI

- `ChatInput` is **not** disabled merely because the active session is busy
- Queued user rows: same `ChatMessage` bubble plus a short **Queued** label
- Thinking row still shows `streamHint` / inspect lines / Stop for the **current** turn

## Tests

`tests/test_ask_alfa_turn_queue.py` asserts the widget source keeps send-while-busy
and the queue helper FIFO / cap contract.
