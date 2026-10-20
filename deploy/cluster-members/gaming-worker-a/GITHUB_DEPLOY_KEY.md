# gaming-worker-a (gaming-a) -- GitHub deploy key (git pull)

Same as [gaming-worker-b-249/GITHUB_DEPLOY_KEY.md](../gaming-worker-b-249/GITHUB_DEPLOY_KEY.md).

## From `gaming-a` (PowerShell as Corey)

```powershell
cd C:\Users\Corey\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\Ensure-GitHubDeployKey.ps1 `
  -Comment gaming-worker-a-219-Corey `
  -RepoRoot C:\Users\Corey\alfa-ai
```

Add the printed public key at https://github.com/example/alfa-ai/settings/keys
(read-only). Title: `gaming-worker-a-219-Corey`.

```powershell
ssh -T operator@example.com
git pull --ff-only origin main
```
