# ARCHIVED: Alfa-AI control of rankings-bot deploy / public ingress on apps

Date archived: 2026-06-30

Reason:
- This code lived in the alfa-ai repo and was responsible for starting, stopping, and verifying the rankings-bot + probilliards-nginx + cf-probilliards tunnel.
- It did so via:
  - stacksapps.yml declaring the bot stacks
  - apps-105/deploy.sh (and boot-all-stacks) driving compose for them + post-step calling the wrappers
  - The two thin ingress start/verify scripts that existed only to be invoked from the alfa-ai runner
- Per segregation policy: rankings-bot now lives on its own host(s) and must control its own full lifecycle exclusively via the scripts/ folder inside the rankings-bot checkout.
- Alfa-ai may integrate with the bot (AI features the bot calls), and the AI may edit bot source, but alfa-ai deploy/orchestration must not own or drive the bot's start/stop/compose/ingress.

Is this code helping rankings-bot?
- No. It was alfa-ai's fleet management reaching across repo boundaries to control the bot.
- Shared build artifacts (bake, wheels, base images) and integration docs were left in place because they do help a standalone bot.

What was moved here:
- start-rankings-public-ingress-105.sh (full)
- verify-rankings-public-ingress-105.sh (full)
- Excerpts from stacksapps.yml (the two bot stacks)
- Excerpt from deploy.sh (the rankings special-case block + related usage comments)

Future:
- Operator may delete this directory once apps no longer needs historical reference and all consumers have switched to the bot's own scripts.
- Do not restore this pattern for controlling any segregated bot.

Related commits (historical, kept for audit):
- 3e95bc9 (2026-04-18) — introduced as part of brain move to make apps the apps host
- 5dd9b7f (2026-06-29) — last fix to keep the ingress working across deploys
