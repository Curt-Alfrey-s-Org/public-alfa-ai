# gaming-worker-b (gaming-b) -- GitHub deploy key (git pull)

Private repo `example/alfa-ai` needs SSH deploy key on each gaming
worker (same pattern as `rag` / fleet VMs). HTTPS clone works once; **`git pull`**
needs this key.

Official: [Managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)

## Step 1 -- From `gaming-b` (PowerShell as Cody)

```powershell
cd C:\Users\Cody\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\Ensure-GitHubDeployKey.ps1 `
  -Comment gaming-worker-b-249-Cody `
  -RepoRoot C:\Users\Cody\alfa-ai
```

Copy the **`ssh-ed25519 AAAA...`** line from the script output.

## Step 2 -- GitHub (browser)

1. Open https://github.com/example/alfa-ai/settings/keys
2. **Add deploy key**
3. Title: `gaming-worker-b-249-Cody`
4. Key: paste the public line
5. **Read-only** (do not enable write)

## Step 3 -- From `gaming-b` (Cody) verify

```powershell
ssh -T operator@example.com
cd C:\Users\Cody\alfa-ai
git pull --ff-only origin main
```

First `ssh -T` may ask to trust `github.com` host key -- type `yes`.

## Bootstrap without script (first clone)

If the repo is not on disk yet, run Step 1 without `-RepoRoot`, add the key to
GitHub, then:

```powershell
git clone operator@example.com:example/alfa-ai.git C:\Users\Cody\alfa-ai
```

## Related

- [AGENT_SSH_FROM_93.md](AGENT_SSH_FROM_93.md) -- Cursor/agent SSH from `orchestrator` (separate key)
- [gaming-worker-a-219/GITHUB_DEPLOY_KEY.md](../gaming-worker-a-219/GITHUB_DEPLOY_KEY.md) -- same flow for Corey
