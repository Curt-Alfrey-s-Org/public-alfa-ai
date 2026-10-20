# Windows gaming display glitches (tearing, flicker, texture corruption)

Use this on **any Windows 10/11 PC** in the fleet (`orchestrator`, `gaming-c`, `gaming-a`, `gaming-b`, gaming workers) when a game shows screen glitching, tearing, flicker, or brief texture corruption — especially on dual-monitor setups with an NVIDIA discrete GPU and an AMD/Intel iGPU.

Validated fix order from a Helldivers 2 session on `orchestrator` (RTX 3060, dual Samsung G5, 32 GB RAM). The same steps apply to other DirectX titles with similar symptoms.

## Symptoms vs what Event Viewer usually shows

| What you see | Likely cause | Typical Event Viewer signal |
|--------------|--------------|-----------------------------|
| Tearing, frame pacing spikes | VSync off + uncapped FPS on a low refresh mode (e.g. 59 Hz instead of 180 Hz) | Often **nothing** in System log |
| Flicker in exclusive fullscreen | Exclusive fullscreen + overlay (NVIDIA App) + frame limiters fighting | Display **Auto HDR** prompts (Event ID 4127) |
| Texture pop / corruption then crash | Pagefile too small; virtual memory denied | **Event 26** — “Virtual Memory Minimum Too Low”; then **Application Error 1000** |
| Hard crash, same offset every time | Game bug or bad memory state after low VM | **APPCRASH** `0xc0000005`, same fault offset in WER |
| Full-screen flash / black flash | HDR mode switching | Display provider **4127** (Auto HDR suggestion) |
| True GPU hang (driver reset) | Driver TDR / device hung | **nvlddmkm** Event **4101**, or game `DXGI_ERROR_DEVICE_HUNG` in a GPU dump |

If there is **no** `nvlddmkm` / “display driver stopped responding” entry, treat tearing and flicker as **configuration** first — not a dying GPU.

## Before you start

1. Close the game (required for pagefile change and display mode changes).
2. Note which GPU ports your monitors use: cables must plug into the **discrete GPU** (NVIDIA), not the motherboard (iGPU).
3. Open **Event Viewer** → **Windows Logs** → **Application** and **System** if you want to confirm the pattern above.

## Fix order (do in this sequence)

### 1. Grow the pagefile, then reboot

A 2 GB pagefile on a 32 GB system caused “Virtual Memory Minimum Too Low” immediately before game crashes.

1. Press **Win**, search **View advanced system settings**, open it.
2. **Advanced** tab → **Performance** → **Settings**.
3. **Advanced** tab → **Virtual memory** → **Change**.
4. Uncheck **Automatically manage paging file size for all drives**.
5. Select **C:** (or the drive Windows boots from).
6. **Custom size**:
   - **Initial size (MB):** `16384`
   - **Maximum size (MB):** `32768`
7. Click **Set** → **OK** on every dialog.
8. **Reboot** when prompted.

**Rule of thumb:** on systems with 16–32 GB RAM, use at least 16 GB initial pagefile; 32 GB max is safe on large SSDs.

### 2. Windows display: correct refresh rate and Auto HDR off

Do this on **each** monitor.

**Refresh rate**

1. Right-click desktop → **Display settings**.
2. Select a monitor → **Advanced display** (or **Display** → **Advanced display settings**).
3. **Choose a refresh rate** → pick the **highest** stable value (e.g. **180 Hz** on a 180 Hz panel, not 59/60 Hz).
4. Repeat for the second monitor.

If the high refresh rate is missing:

- Use **DisplayPort** from the **NVIDIA** card (preferred for 1440p high refresh).
- Avoid a weak HDMI mode or a cable plugged into the **motherboard** video port.

**Auto HDR**

1. **Display settings** → **HDR** (or **Use HDR**).
2. Turn **Auto HDR** **Off** unless you deliberately run HDR in the game.
3. Keep game HDR off if Windows Auto HDR is off (mixed settings cause mode-switch flashes).

### 3. Force the discrete NVIDIA GPU

Applies when Windows lists **AMD Radeon / Intel** graphics **above** **NVIDIA GeForce** in Device Manager or Task Manager → Performance.

**NVIDIA App** (current default; e.g. NVIDIA App 11.x)

1. Open **NVIDIA App** from Start.
2. Go to **Graphics** (or **System → Graphics**).
3. Add or select the game executable (e.g. `helldivers2.exe` under your Steam library path).
4. Set GPU preference to **NVIDIA GeForce** / **High performance**.

**NVIDIA Control Panel** (same policy, older UI)

1. Right-click desktop → **NVIDIA Control Panel**.
2. **3D Settings** → **Manage 3D settings** → **Program Settings**.
3. Add the game `.exe` if missing.
4. **Preferred graphics processor** → **High-performance NVIDIA processor** → **Apply**.

**Cables:** unplug any monitor from motherboard HDMI/DP; use only ports on the NVIDIA card.

### 4. Turn off NVIDIA Overlay (test session)

NVIDIA Overlay processes (`NVIDIA Overlay`, `nvcontainer`) often cause flicker in **exclusive fullscreen**.

1. Open **NVIDIA App** → **Settings** (gear).
2. **Features** / **Overlay** → turn **NVIDIA Overlay** **Off**.
3. Confirm Alt+Z does not open in-game.
4. Play one session; if glitches stop, leave overlay off for that title.

*(GeForce Experience: **Settings → General → In-Game Overlay** → Off.)*

### 5. In-game video settings

Apply after steps 1–3 (reboot done) and display refresh is correct.

| Setting | Recommended | Why |
|---------|-------------|-----|
| Display mode | **Borderless window** | Fewer exclusive-fullscreen + overlay conflicts |
| VSync | **On**, or off with a **FPS cap** matching refresh | Stops tearing on fixed refresh |
| Framerate limit | Match monitor Hz (e.g. **180** or **60**) | Avoid uncapped frames on 59 Hz desktop mode |
| AMD Anti-Lag | **Off** on NVIDIA systems | Conflicts with NVIDIA Reflex / driver pacing |
| NVIDIA Reflex | **On** (not **On + Boost** first) | Boost can add pacing stress; try Off if flicker remains |
| HDR (in game) | **Off** if Windows Auto HDR is off | Prevents HDR toggle flashes |

Restart the game once after changing display mode or FPS limit so the swapchain rebuilds.

## Verification checklist

After all steps:

- [ ] **Pagefile:** `AllocatedBaseSize` ≥ 16384 MB (PowerShell: `Get-CimInstance Win32_PageFileUsage`).
- [ ] **Refresh:** Both monitors show target Hz in **Advanced display** (not 59 Hz on a 180 Hz panel).
- [ ] **GPU:** Game uses NVIDIA in Task Manager → Performance → GPU (or NVIDIA overlay performance widget).
- [ ] **Event Viewer:** No new **Event 26** (low virtual memory) during play.
- [ ] **Play test:** One full mission / 15+ minutes without tearing, flicker, or crash.

## Quick diagnosis commands (PowerShell)

Run on the Windows host after a bad session:

```powershell
# Pagefile
Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, PeakUsage

# GPUs and current desktop refresh
Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, CurrentRefreshRate, VideoModeDescription

# Game crashes today (replace helldivers with your game exe name)
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000; StartTime=(Get-Date).Date} -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'helldivers|\.exe' } |
  Select-Object TimeCreated, @{N='Msg';E={$_.Message.Substring(0,[Math]::Min(200,$_.Message.Length))}}

# Low virtual memory (pagefile)
Get-WinEvent -FilterHashtable @{LogName='System'; Id=26; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Message

# GPU driver TDR (last 7 days)
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -match 'nvlddmkm|Display' -or $_.Message -match 'TDR|stopped responding' } |
  Select-Object TimeCreated, Id, ProviderName, @{N='Msg';E={$_.Message.Substring(0,[Math]::Min(200,$_.Message.Length))}}
```

Game-specific crash dumps (if enabled): `%LOCALAPPDATA%\CrashDumps\` and `C:\ProgramData\Microsoft\Windows\WER\ReportArchive\`.

## When these fixes are not enough

- **Repeating `nvlddmkm` Event 4101** or `DXGI_ERROR_DEVICE_HUNG` in a game GPU dump → driver clean install, thermals, power limit, then hardware.
- **Same `0xc0000005` offset** with plenty of pagefile and stable display → game patch or verify game files (Steam **Verify integrity**).
- **Only one title** → title-specific forums; keep this doc’s display/GPU/pagefile baseline anyway.

## Related docs

- [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md) — Windows host prerequisites (`orchestrator` and gaming workers)
- [WINDOWS_WSL_DOCKER_ENGINE.md](WINDOWS_WSL_DOCKER_ENGINE.md) — WSL + Docker on Windows fleet hosts
- [WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md) — disk and cache hygiene on Windows
- [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md) — opt-in gaming GPUs without display glitches blocking play
- [LAN_OPERATOR_TROUBLESHOOTING.md](LAN_OPERATOR_TROUBLESHOOTING.md) — cross-host failures (not display-specific)
