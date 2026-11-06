# GLKVM Screen Switcher

**Auto-switch the Windows display topology for a GLKVM / PiKVM box.**
Keep the physical monitor on its own (high refresh + HDR) while you are at the desk,
and duplicate the desktop to the KVM's emulated display the moment a remote client
actually watches the stream — then go back to single screen when they leave.

[中文说明](#中文说明) · [MIT License](LICENSE)

---

## The problem

A KVM-over-IP box (GL.iNet GLKVM, PiKVM, …) shows up in Windows as an extra monitor
with a **3840×2160 @ 30 Hz** EDID. If you leave the desktop in *Duplicate* mode:

* Windows makes the ghost display the **primary** output, so the whole desktop is
  composited at **30 Hz** — every browser animation, game and scroll is capped at 30 fps;
* **HDR is disabled**, because the emulated sink is SDR only.

If you instead switch to *Show only on 1* (your real monitor), everything is fine —
until you leave the house and realise you forgot to switch back, and the KVM shows
a black screen.

## What it does

| Situation | Action |
|---|---|
| Nobody is watching | single screen on the physical monitor (e.g. 4K@165 Hz + HDR) |
| A GLKVM client connects | duplicate the desktop within ~2 s, physical monitor kept as primary (still 165 Hz) |
| The client disconnects | back to single screen in ~10–15 s, HDR restored automatically |
| KVM unreachable | changes nothing (never switch blind) |
| Desktop is *Extended* | changes nothing (only duplicate setups are managed) |

No timers, no schedule, no "idle for N minutes" heuristics — the trigger is literally
"is a client consuming the KVM video stream right now".

## How it knows someone is watching

It asks the KVM itself, using the PiKVM HTTP API:

```
POST /api/auth/login          -> token
GET  /api/streamer?auth_token=...
     -> result.streamer.sinks.h264.has_clients   (or sinks.jpeg.has_clients)
```

`has_clients` becomes `true` while a browser/app is pulling the video stream and goes
back to `false` when it stops. When no streamer instance exists at all the field is
`null`, which also means "nobody".

## Requirements

* Windows 10 / 11 (tested on Windows 11 26100)
* Windows PowerShell 5.1 (built in — no PowerShell 7 needed)
* A KVM that speaks the PiKVM `kvmd` API (GL.iNet GLKVM, PiKVM v3, …)
* Network access from the PC to the KVM (`https://glkvm.local` by default)

## Install

```powershell
git clone https://github.com/<you>/glkvm-screen-switcher.git C:\tools\glkvm-screen-switcher
cd C:\tools\glkvm-screen-switcher
notepad config.example.json      # save as config.json and edit the two values below
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Two things you must fill in `config.json`:

* `physicalTarget` — the exact monitor name of your real screen;
* `kvmUser` / `kvmPassword` — the credentials of the KVM web interface.

To find the monitor name, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\GlkvmScreenSwitcher.ps1 -Mode detect
```

It prints every active display with its refresh rate and HDR support, e.g.

```
Active displays (use the exact name as physicalTarget / kvmTarget):
  - '27U8A Pro-S'  165 Hz   hdr=0,1,1,10
  - 'ASUS'         30 Hz    hdr=0,0,0,8
duplicate topology: True
kvm api reachable : True
```

## Usage

```powershell
# status: topology, KVM client state, HDR state, task and process
powershell -ExecutionPolicy Bypass -File .\status.ps1

# one-shot switches (the daemon will take over again)
powershell -ExecutionPolicy Bypass -File .\GlkvmScreenSwitcher.ps1 -Mode solo
powershell -ExecutionPolicy Bypass -File .\GlkvmScreenSwitcher.ps1 -Mode clone

# pause / resume the daemon
New-Item .\state\pause.flag
Remove-Item .\state\pause.flag

# remove the scheduled task
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `physicalTarget` | — | monitor name of the real screen (must match exactly) |
| `kvmBaseUrl` | `https://glkvm.local` | KVM web UI base URL |
| `kvmUser` / `kvmPassword` | — | KVM web credentials |
| `pollSeconds` | `5` | how often the KVM is queried |
| `revertAfterMisses` | `2` | consecutive "nobody" polls before switching back (1 = fastest, but a page reload causes a blink) |
| `cloneDwellSeconds` | `10` | minimum time to stay duplicated after a switch, avoids flip-flop while the stream re-handshakes |
| `revertToSoloWhenIdle` | `true` | `false` = stay duplicated forever |
| `ensureHdrOnSolo` | `true` | after switching back, check HDR and re-enable it if supported but off |

`config.json`, `logs/` and `state/` are git-ignored — they contain your credentials
(the password is stored in plain text, the file is only readable by you).

## How it works (the interesting bits)

* **`SetDisplayConfig` with explicit paths.** `DisplaySwitch.exe /internal|/external`
  does nothing here: in duplicate mode Windows sees a single logical display. The
  script instead builds path lists from `QueryDisplayConfig(QDC_ALL_PATHS)` and
  applies them with `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_SAVE_TO_DATABASE
  | SDC_ALLOW_CHANGES`.
* **Restoring a duplicate needs a snapshot.** Once you drop to single screen, Windows
  stops enumerating the ghost target entirely — it cannot be re-attached from scratch.
  The script therefore captures a `state/clone.b64` snapshot while duplicated and
  replays it (patching the adapter LUID, which changes across reboots).
* **Primary first.** Windows composites a duplicate at the refresh rate of the first
  path. Putting the physical monitor first is what turns a 30 Hz desktop into 165 Hz.
* **HDR is per-display state** that Windows keeps; it comes back by itself when the
  duplicate is removed. The script only re-enables it as a safety net, via
  `DisplayConfigSetDeviceInfo(DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE)`.

## Known limitations

* The KVM side stays at its own capture rate (often 4K@30); that is the KVM's limit,
  not the script's.
* While duplicated, HDR is off — unavoidable, the emulated sink is SDR.
* Does not survive the PC being asleep or off.
* Renaming/replugging monitors changes `physicalTarget`; re-run `-Mode detect`.
* If the very first run happens while *not* duplicated, no snapshot exists yet, so
  the "switch to duplicate" direction cannot work until you duplicate once by hand.

## Tested with

Windows 11 26100 · GL.iNet GLKVM (kvmd 4.82, RV1126B capture, 4K@30 EDID) ·
RTX 5080 · ASUS ProArt 27U8A (4K@165, HDR).

---

## 中文说明

**为 GLKVM / PiKVM 自动切换 Windows 显示模式。**
人在电脑前时保持单屏（高刷新率 + HDR）；有人远程连上 KVM 时自动切成复制，
让远端看到画面；人走开后再自动切回单屏，HDR 也回来。

### 要解决的问题

KVM-over-IP 盒子（GL.iNet GLKVM、PiKVM 等）在 Windows 里会伪装成一台
**3840×2160 @ 30Hz** 的显示器。如果一直保持"复制"模式：

* Windows 会把这台"假显示器"当成**主输出**，整个桌面被压到 **30Hz**，
  浏览器动画、游戏、滚动全部 30 帧封顶；
* **HDR 会被关掉**，因为虚拟出来的那路只支持 SDR。

如果改成"仅在 1 上显示"（只留物理屏），一切正常——但你出门忘了切回来，
远程连上去就是黑屏。

### 它做什么

| 状态 | 行为 |
|---|---|
| 没人看 | 单屏（例如 4K@165Hz + HDR） |
| 有人连上 KVM | 约 2 秒内切成复制，物理屏仍是主输出（165Hz） |
| 对方断开 | 约 10~15 秒切回单屏，HDR 自动恢复 |
| KVM 连不上 | 什么都不做，绝不瞎切 |
| 当前是"扩展"模式 | 什么都不做，只管复制模式 |

没有定时器、没有"闲置 N 分钟"这类猜测，触发条件就是
"此刻有没有客户端在拉 KVM 的视频流"。

### 怎么判断有人在看

直接问 KVM 自己（PiKVM HTTP API）：

```
POST /api/auth/login          → token
GET  /api/streamer?auth_token=...
     → result.streamer.sinks.h264.has_clients   （或 sinks.jpeg.has_clients）
```

有人拉流时 `has_clients=true`，断开后变 `false`；完全没有 streamer 实例时该字段为
`null`，同样表示"没人"。

### 安装

```powershell
git clone https://github.com/<you>/glkvm-screen-switcher.git C:\tools\glkvm-screen-switcher
cd C:\tools\glkvm-screen-switcher
# 把 config.example.json 复制为 config.json 并填两项
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

必填两项：

* `physicalTarget`：你物理显示器的名字（必须完全一致）；
* `kvmUser` / `kvmPassword`：KVM 网页登录账号。

不知道显示器叫什么？运行 `-Mode detect`，会列出所有在用显示器的名字、刷新率和
HDR 状态，直接抄进配置即可。

### 常用命令

```powershell
powershell -ExecutionPolicy Bypass -File .\status.ps1                                  # 看状态
powershell -ExecutionPolicy Bypass -File .\GlkvmScreenSwitcher.ps1 -Mode solo          # 手动单屏
powershell -ExecutionPolicy Bypass -File .\GlkvmScreenSwitcher.ps1 -Mode clone         # 手动复制
New-Item .\state\pause.flag                                                            # 暂停守护
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1                               # 卸载
```

### 原理

* **用 `SetDisplayConfig` 直接指定路径**。`DisplaySwitch.exe` 在这里没用——复制模式下
  Windows 只认一个逻辑显示器，`/internal`、`/external` 都是空操作。
* **恢复复制需要快照**。切到单屏后 Windows 会彻底忘记那台假显示器，没法凭空接回来，
  所以脚本在复制状态下把配置存进 `state/clone.b64`，需要时原样重放
  （并修补重启后会变化的 adapter LUID）。
* **物理屏排第一**。Windows 用第一个路径的刷新率合成整张桌面，这一步才是把 30Hz 变回 165Hz 的关键。
* **HDR 是每个显示器的独立状态**，去掉复制后 Windows 会自己恢复；脚本只做兜底补开。

### 已知限制

* KVM 那边仍是它自己的采集上限（常见 4K@30），这是硬件限制。
* 复制期间 HDR 必然关闭（虚拟输出只有 SDR），无法绕开。
* 电脑睡眠/关机时无解。
* 换接口/换线导致显示器改名后，需要重跑 `-Mode detect` 更新配置。
* 如果第一次运行时**不是**复制状态，还没有快照，"切复制"这个方向暂时不可用，
  需要先手动切成一次复制。

### 测试环境

Windows 11 26100 · GL.iNet GLKVM（kvmd 4.82，RV1126B 采集，4K@30 EDID）·
RTX 5080 · ASUS ProArt 27U8A（4K@165，HDR）。

## License

[MIT](LICENSE)
