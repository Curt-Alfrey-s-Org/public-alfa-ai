/** In-app Users Manual content. Public sections: no LAN IPs / topology.
 * Admin sections: console how-to only; shown when user.is_admin.
 * SSoT prose: docs/USERS_MANUAL.md
 */

export type ManualSection = {
  id: string;
  title: string;
  body: string[];
};

/** Visible to guests and signed-in users. */
export const userManualSections: ManualSection[] = [
  {
    id: "start",
    title: "Getting started",
    body: [
      "Open the chat app and sign in, or use Guest chat for a limited trial without an account.",
      "Signed-in users get full chat history and account settings (password, optional 2FA).",
      "Use About for a short overview of the platform and model tiers.",
    ],
  },
  {
    id: "chat",
    title: "How to chat",
    body: [
      "Type in the box at the bottom and press Send. Replies stream in as they are generated.",
      "Pick a model from the header menu when you need a different speed or quality tradeoff.",
      "Use the left Chats sidebar to continue an old thread (click a title), search chats, rename the title, or delete.",
      "To change a prompt and re-run: hover your message in the main pane and choose Edit & regenerate (sidebar pencil only renames the chat title).",
      "Start a new conversation with the + button in the sidebar when you want a clean thread (faster replies).",
    ],
  },
  {
    id: "account",
    title: "Account and security",
    body: [
      "Change your password under Password in the chat header.",
      "Enable two-factor authentication from Enable 2FA when prompted (recommended for accounts with elevated access).",
      "Sign out from the header when you finish on a shared device.",
    ],
  },
  {
    id: "models",
    title: "Choosing a model",
    body: [
      "Default chat is fine for everyday questions.",
      "Use a stronger coding or frontier tier when you need deeper reasoning or larger refactors.",
      "See About → Model tiers for the customer-facing ranking (smartest to simplest).",
    ],
  },
];

/** Only rendered when AuthContext user.is_admin === true. */
export const adminManualSections: ManualSection[] = [
  {
    id: "admin-console",
    title: "Admin console",
    body: [
      "Admins see an Admin link in the chat header. It opens the operator console (Health, Monitoring, AI Actions, and more).",
      "Admin routes require an admin account. Network policy may also restrict where admin login works.",
      "Non-admin users never see this section or the Admin link.",
    ],
  },
  {
    id: "admin-health",
    title: "Health and monitoring",
    body: [
      "Health shows brain and related service status for operators.",
      "Monitoring (incidents) lists alerts and remediation-related items from the incident queue.",
      "Use these tabs to confirm the stack is healthy before changing AI settings or approving host actions.",
    ],
  },
  {
    id: "admin-ai-actions",
    title: "AI Actions and Ask ALFa",
    body: [
      "AI Actions holds agent settings, history, and host-action controls.",
      "Ask ALFa can propose catalog or freeform host commands; every proposal stays pending until you Approve.",
      "Read the exact command text before approving. Do not approve piecemeal pool shard restarts — use the cluster start/stop orchestrator path documented in the repo.",
    ],
  },
  {
    id: "admin-other",
    title: "Models, editor, users, audit",
    body: [
      "Models summarizes configured chat and inference aliases for operators.",
      "Editor is for operator workspace edits when that feature is enabled.",
      "Users manages accounts and roles; Audit Log shows security-relevant events.",
    ],
  },
  {
    id: "admin-ops-docs",
    title: "Full operator runbooks",
    body: [
      "Cluster start/stop, hub artifacts, and host deploy steps live in the alfa-ai docs tree (INDEX, CLUSTER_START_STOP_OPERATOR, and per-host operator guides).",
      "This in-app section is a console how-to only — use the repo docs for deploy and recovery.",
    ],
  },
];
