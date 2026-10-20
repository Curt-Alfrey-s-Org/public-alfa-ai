# Docs that described the archived control path

These sections in alfa-ai docs told operators to use the (now archived) alfa-ai apps-105 mechanism to start/stop/verify the rankings-bot public site.

Primary file:
- docs/DOCKGE_105_OPERATOR.md
  - "Rankings public site (probilliardssoftware.com)" section
  - Commands such as:
      bash deploy/cluster-members/apps/deploy.sh --only=rankings-bot,probilliards-nginx
  - Table that says Cloudflare tunnel is driven by `start-rankings-public-ingress-105.sh` (post-step of deploy.sh)
  - Verify command referencing the archived wrapper

Other scattered references (mostly descriptive or historical):
- docs/history/BRAIN_MIGRATION_105_TO_111.md (shows direct `cd /home/operator/rankings-bot && docker compose restart` — this is closer to "use the bot's own tooling")
- Various "use apps-105/deploy.sh for the fleet including bots" sentences

Action for segregation:
- When updating operator docs for apps, remove or clearly mark as historical any instruction that says "run the alfa-ai deploy to start the rankings bot".
- The rankings-bot owns `cd <rankings-bot-checkout> && ./scripts/<its-full-deploy-or-start-script>`.
- Alfa-ai docs should only document how alfa-ai components integrate with the bot (ALFA_AI_API_URL, LiteLLM usage, etc.), not how to deploy the bot itself.
