#requires -Version 5.1
<#
.SYNOPSIS
    Switches the Windows display topology on demand for a GLKVM / PiKVM box.

.DESCRIPTION
    Keeps the desktop on the physical monitor only (so 165 Hz and HDR stay available),
    and duplicates the desktop to the KVM's emulated display the moment a remote
    client actually watches the stream. When the client goes away the desktop
    returns to the physical monitor.

    The "is somebody watching" signal comes from the KVM itself:
        GET /api/streamer -> result.streamer.sinks.h264.has_clients

.PARAMETER Mode
    run     - daemon loop (default, used by the scheduled task)
    solo    - switch to physical monitor only, then exit
    clone   - restore the duplicated desktop from the saved snapshot, then exit
    status  - print display state / KVM state / HDR state, then exit
    detect  - print every connected display and its HDR support, then exit

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File GlkvmScreenSwitcher.ps1 -Mode status
#>

param(
    [string]$Root = $PSScriptRoot,
    [ValidateSet('run', 'solo', 'clone', 'status', 'detect')]
    [string]$Mode = 'run'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

$configPath = Join-Path $Root 'config.json'
$logDir     = Join-Path $Root 'logs'
$stateDir   = Join-Path $Root 'state'
$blobPath   = Join-Path $stateDir 'clone.b64'
$pauseFlag  = Join-Path $stateDir 'pause.flag'
New-Item -ItemType Directory -Force -Path $logDir, $stateDir | Out-Null

if (-not (Test-Path $configPath)) {
    Write-Host "config.json not found next to the script. Copy config.example.json to config.json and edit it."
    exit 1
}

$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
$physName  = $cfg.physicalTarget
$pollSec   = if ($cfg.pollSeconds) { [int]$cfg.pollSeconds } else { 5 }
$missLimit = if ($cfg.revertAfterMisses) { [int]$cfg.revertAfterMisses } else { 2 }
$dwellSec  = if ($cfg.cloneDwellSeconds) { [int]$cfg.cloneDwellSeconds } else { 10 }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $logFile = Join-Path $logDir 'switcher.log'
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 2MB)) { Move-Item $logFile ($logFile + '.1') -Force }
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch { }
    if ($Mode -ne 'run') { Write-Host $line }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
using System.Globalization;

public class Switcher {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public uint hzNum; public uint hzDen; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC s; public TGT t; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct MODE { public uint infoType; public uint id; public LUID adapterId; public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] public struct HDRH { public uint type; public uint size; public LUID adapterId; public uint id; }
  [StructLayout(LayoutKind.Sequential)] public struct GETINFO { public HDRH header; public uint value; public uint colorEncoding; public uint bitsPerColorChannel; }
  [StructLayout(LayoutKind.Sequential)] public struct SETINFO { public HDRH header; public uint value; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TGTNAME { public HDRH header; public uint flags; public uint outputTechnology; public ushort mfg; public ushort prod; public uint connector; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string friendly; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string path; }

  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr t);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, [In] PATH[] p, uint nm, [In] MODE[] m, uint flags);
  [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetDevInfo(ref GETINFO r);
  [DllImport("user32.dll", EntryPoint="DisplayConfigSetDeviceInfo")] static extern int SetDevInfo(ref SETINFO r);
  [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] static extern int NameGet(ref TGTNAME r);

  const uint APPLY = 0x20u | 0x80u | 0x200u | 0x400u;   // USE_SUPPLIED | APPLY | SAVE_TO_DATABASE | ALLOW_CHANGES

  public static string TName(PATH p) {
    var n = new TGTNAME();
    n.header.type = 2;
    n.header.size = (uint)Marshal.SizeOf(typeof(TGTNAME));
    n.header.adapterId = p.t.adapterId;
    n.header.id = p.t.id;
    NameGet(ref n);
    return n.friendly == null ? "?" : n.friendly;
  }

  static void Query(uint flags, out PATH[] paths, out MODE[] modes) {
    uint np, nm;
    GetDisplayConfigBufferSizes(flags, out np, out nm);
    var p = new PATH[np + 16];
    var m = new MODE[nm + 32];
    uint a = (uint)(np + 16), b = (uint)(nm + 32);
    int err = QueryDisplayConfig(flags, ref a, p, ref b, m, IntPtr.Zero);
    if (err != 0) throw new Exception("QueryDisplayConfig failed: " + err);
    var pl = new List<PATH>();
    for (int i = 0; i < (int)a; i++) pl.Add(p[i]);
    var ml = new List<MODE>();
    for (int i = 0; i < (int)b; i++) ml.Add(m[i]);
    paths = pl.ToArray();
    modes = ml.ToArray();
  }

  public static string ActiveJson() {
    PATH[] p; MODE[] m;
    Query(2, out p, out m);
    bool dup = false;
    if (p.Length > 1) {
      dup = true;
      for (int i = 1; i < p.Length; i++) if (p[i].s.id != p[0].s.id) dup = false;
    }
    var sb = new StringBuilder();
    sb.Append("{\"count\":").Append(p.Length).Append(",\"duplicate\":").Append(dup ? "true" : "false").Append(",\"paths\":[");
    for (int i = 0; i < p.Length; i++) {
      if (i > 0) sb.Append(',');
      double hz = p[i].t.hzDen == 0 ? 0 : (double)p[i].t.hzNum / p[i].t.hzDen;
      string nm = TName(p[i]).Replace("\\", "\\\\").Replace("\"", "\\\"");
      sb.Append("{\"name\":\"").Append(nm).Append("\",\"hz\":").
         Append(hz.ToString("F1", CultureInfo.InvariantCulture)).Append("}");
    }
    sb.Append("]}");
    return sb.ToString();
  }

  public static string Capture() {
    PATH[] p; MODE[] m;
    Query(1, out p, out m);
    int ps = Marshal.SizeOf(typeof(PATH)), ms = Marshal.SizeOf(typeof(MODE));
    byte[] bytes = new byte[8 + p.Length * ps + m.Length * ms];
    BitConverter.GetBytes((uint)p.Length).CopyTo(bytes, 0);
    BitConverter.GetBytes((uint)m.Length).CopyTo(bytes, 4);
    IntPtr b1 = Marshal.AllocHGlobal(p.Length * ps);
    for (int i = 0; i < p.Length; i++) Marshal.StructureToPtr(p[i], new IntPtr(b1.ToInt64() + (long)i * ps), false);
    Marshal.Copy(b1, bytes, 8, p.Length * ps);
    Marshal.FreeHGlobal(b1);
    IntPtr b2 = Marshal.AllocHGlobal(m.Length * ms);
    for (int i = 0; i < m.Length; i++) Marshal.StructureToPtr(m[i], new IntPtr(b2.ToInt64() + (long)i * ms), false);
    Marshal.Copy(b2, bytes, 8 + p.Length * ps, m.Length * ms);
    Marshal.FreeHGlobal(b2);
    return Convert.ToBase64String(bytes);
  }

  static PATH[] UnpackPaths(byte[] raw, int off, int n) {
    int ps = Marshal.SizeOf(typeof(PATH));
    var res = new PATH[n];
    IntPtr buf = Marshal.AllocHGlobal(n * ps);
    Marshal.Copy(raw, off, buf, n * ps);
    for (int i = 0; i < n; i++) res[i] = (PATH)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + (long)i * ps), typeof(PATH));
    Marshal.FreeHGlobal(buf);
    return res;
  }
  static MODE[] UnpackModes(byte[] raw, int off, int n) {
    int ms = Marshal.SizeOf(typeof(MODE));
    var res = new MODE[n];
    IntPtr buf = Marshal.AllocHGlobal(n * ms);
    Marshal.Copy(raw, off, buf, n * ms);
    for (int i = 0; i < n; i++) res[i] = (MODE)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + (long)i * ms), typeof(MODE));
    Marshal.FreeHGlobal(buf);
    return res;
  }

  // The physical display must be the first path of a duplicate, otherwise Windows
  // composites the desktop at the emulated 30 Hz display's refresh rate.
  public static string Reorder(string physName) {
    PATH[] p; MODE[] m;
    Query(2, out p, out m);
    if (p.Length < 2) return "skip:active=" + p.Length;
    for (int i = 1; i < p.Length; i++) if (p[i].s.id != p[0].s.id) return "skip:not-duplicate";
    if (TName(p[0]) == physName) return "ok:already-primary";
    PATH phys = new PATH(); bool found = false;
    foreach (var x in p) if (TName(x) == physName) { phys = x; found = true; break; }
    if (!found) return "err:physical-not-active";
    var list = new List<PATH>();
    list.Add(phys);
    foreach (var x in p) if (TName(x) != physName) list.Add(x);
    int rc = SetDisplayConfig((uint)list.Count, list.ToArray(), (uint)m.Length, m, APPLY);
    return (rc == 0) ? "ok:reordered" : "err:SetDisplayConfig=" + rc;
  }

  public static string ApplyBlob(string b64, bool patchAdapter) {
    byte[] bytes = Convert.FromBase64String(b64);
    int np = (int)BitConverter.ToUInt32(bytes, 0);
    int nm = (int)BitConverter.ToUInt32(bytes, 4);
    int ps = Marshal.SizeOf(typeof(PATH));
    var paths = UnpackPaths(bytes, 8, np);
    var modes = UnpackModes(bytes, 8 + np * ps, nm);
    if (patchAdapter) {
      PATH[] cur; MODE[] curM;
      Query(2, out cur, out curM);
      if (cur.Length > 0) {
        LUID luid = cur[0].s.adapterId;
        uint sid = cur[0].s.id;
        for (int i = 0; i < paths.Length; i++) {
          paths[i].s.adapterId = luid;
          paths[i].t.adapterId = luid;
          paths[i].s.id = sid;
        }
      }
    }
    int rc = SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, APPLY);
    return (rc == 0) ? "ok" : "err:SetDisplayConfig=" + rc;
  }

  public static string Solo(string physName) {
    PATH[] p; MODE[] m;
    Query(1, out p, out m);
    var list = new List<PATH>();
    foreach (var x in p) if ((x.flags & 1u) != 0 && TName(x) == physName) list.Add(x);
    if (list.Count == 0) return "err:physical-not-found";
    int rc = SetDisplayConfig((uint)list.Count, list.ToArray(), (uint)m.Length, m, APPLY);
    return (rc == 0) ? "ok" : "err:SetDisplayConfig=" + rc;
  }

  // returns "rc,supported,enabled,bitsPerColor"
  public static string Hdr(string name) {
    PATH[] p; MODE[] m;
    Query(2, out p, out m);
    foreach (var x in p) {
      if (TName(x) != name) continue;
      var g = new GETINFO();
      g.header.type = 9;
      g.header.size = (uint)Marshal.SizeOf(typeof(GETINFO));
      g.header.adapterId = x.t.adapterId;
      g.header.id = x.t.id;
      int rc = GetDevInfo(ref g);
      uint v = g.value;
      return rc + "," + (((v & 1u) != 0) ? 1 : 0) + "," + (((v & 2u) != 0) ? 1 : 0) + "," + g.bitsPerColorChannel;
    }
    return "notfound";
  }

  public static string HdrOn(string name) {
    PATH[] p; MODE[] m;
    Query(2, out p, out m);
    foreach (var x in p) {
      if (TName(x) != name) continue;
      var s = new SETINFO();
      s.header.type = 10;
      s.header.size = (uint)Marshal.SizeOf(typeof(SETINFO));
      s.header.adapterId = x.t.adapterId;
      s.header.id = x.t.id;
      s.value = 1;
      return "rc=" + SetDevInfo(ref s);
    }
    return "notfound";
  }
}
'@ -Language CSharp

# ---------------------------------------------------------------- KVM helpers
$script:kvmToken = $null
$script:kvmTokenTime = [datetime]::MinValue

function Get-KvmToken {
    $r = Invoke-RestMethod -Uri ($cfg.kvmBaseUrl.TrimEnd('/') + '/api/auth/login') -Method Post `
        -Body @{ user = $cfg.kvmUser; passwd = $cfg.kvmPassword } -TimeoutSec 8
    if (-not $r.ok) { throw 'login rejected' }
    $script:kvmToken = $r.result.token
    $script:kvmTokenTime = Get-Date
}

function Test-KvmWatching {
    param([int]$Retry = 2)
    for ($i = 0; $i -lt $Retry; $i++) {
        try {
            if (-not $script:kvmToken -or ((Get-Date) - $script:kvmTokenTime).TotalHours -gt 6) { Get-KvmToken }
            $uri = $cfg.kvmBaseUrl.TrimEnd('/') + '/api/streamer?auth_token=' + $script:kvmToken
            $r = Invoke-RestMethod -Uri $uri -TimeoutSec 8
            $st = $r.result.streamer
            if ($null -eq $st) { return $false }
            $h264 = $false; $jpeg = $false
            if ($st.sinks) {
                if ($st.sinks.h264) { $h264 = [bool]$st.sinks.h264.has_clients }
                if ($st.sinks.jpeg) { $jpeg = [bool]$st.sinks.jpeg.has_clients }
            }
            return ($h264 -or $jpeg)
        } catch {
            $script:kvmToken = $null
            if ($i -lt $Retry - 1) { Start-Sleep -Seconds 2 }
        }
    }
    return $null   # unknown
}

# ------------------------------------------------------------------- actions
function Save-Blob {
    try {
        $b64 = [Switcher]::Capture()
        Set-Content -Path $blobPath -Value $b64 -Encoding ASCII -NoNewline
        return $true
    } catch {
        Write-Log ('snapshot failed: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Enter-Solo {
    $r = [Switcher]::Solo($physName)
    Write-Log ("switch -> solo: $r")
    if ($r -notlike 'err*') {
        Start-Sleep -Milliseconds 2500
        $h = [Switcher]::Hdr($physName)
        Write-Log ("hdr($physName) = $h")
        if ($cfg.ensureHdrOnSolo -and $h -ne 'notfound') {
            $parts = $h.Split(',')
            if ($parts.Count -ge 3 -and $parts[1] -eq '1' -and $parts[2] -ne '1') {
                Write-Log ('re-enabling HDR: ' + [Switcher]::HdrOn($physName))
            }
        }
    }
}

function Enter-Clone {
    if (-not (Test-Path $blobPath)) {
        Write-Log 'no display snapshot yet (start once while duplicated); cannot switch to duplicate' 'WARN'
        return $false
    }
    $b64 = (Get-Content $blobPath -Raw).Trim()
    $r = [Switcher]::ApplyBlob($b64, $true)
    Write-Log ("switch -> duplicate: $r")
    Start-Sleep -Milliseconds 2500
    $after = [Switcher]::ActiveJson() | ConvertFrom-Json
    Write-Log ('duplicate result: count=' + $after.count + ' names=' + (($after.paths | ForEach-Object { $_.name }) -join ','))
    if ([int]$after.count -ge 2) { [Switcher]::Reorder($physName) | Out-Null; return $true }
    return $false
}

# --------------------------------------------------------------- manual modes
if ($Mode -ne 'run') {
    switch ($Mode) {
        'status' {
            $info = [Switcher]::ActiveJson() | ConvertFrom-Json
            Write-Host ('display  : ' + (($info.paths | ForEach-Object { "$($_.name) @ $($_.hz) Hz" }) -join ', ') + "  (duplicate=$($info.duplicate))")
            Write-Host ('watching : ' + (Test-KvmWatching))
            Write-Host ('hdr      : ' + [Switcher]::Hdr($physName) + '   [rc,supported,enabled,bits]')
        }
        'detect' {
            $info = [Switcher]::ActiveJson() | ConvertFrom-Json
            Write-Host 'Active displays (use the exact name as physicalTarget / kvmTarget):'
            foreach ($p in $info.paths) {
                Write-Host ("  - '{0}'  {1} Hz   hdr={2}" -f $p.name, $p.hz, [Switcher]::Hdr($p.name))
            }
            Write-Host ("duplicate topology: {0}" -f $info.duplicate)
            Write-Host ("kvm api reachable : {0}" -f ($null -ne (Test-KvmWatching)))
        }
        'solo'  { Enter-Solo }
        'clone' { [void](Enter-Clone) }
    }
    exit 0
}

# ------------------------------------------------------------------ main loop
Write-Log "switcher started"
Write-Log ("config: physical='$physName' kvm='$($cfg.kvmBaseUrl)' poll=${pollSec}s misses=$missLimit dwell=${dwellSec}s")

$lastState  = ''
$lastBlob   = [datetime]::MinValue
$misses     = 0
$cloneSince = [datetime]::MinValue
$warnedExtend = $false

while ($true) {
    try {
        if (Test-Path $pauseFlag) { Start-Sleep -Seconds $pollSec; continue }

        $info  = [Switcher]::ActiveJson() | ConvertFrom-Json
        $count = [int]$info.count
        $names = @($info.paths | ForEach-Object { $_.name })
        $key   = "$count|$($names -join ',')"
        if ($key -ne $lastState) {
            Write-Log ("display state: count=$count duplicate=$($info.duplicate) names=" + ($names -join ',') + " hz=" + (($info.paths | ForEach-Object { $_.hz }) -join ','))
            $lastState = $key
        }

        # Extended desktop (two independent desktops): not our business.
        if ($count -ge 2 -and -not $info.duplicate) {
            if (-not $warnedExtend) { Write-Log 'extended desktop detected - leaving it alone' 'WARN'; $warnedExtend = $true }
            Start-Sleep -Seconds 30
            continue
        }
        $warnedExtend = $false

        $watching = Test-KvmWatching

        if ($watching -eq $true) {
            $misses = 0
            if ($count -ge 2) {
                $r = [Switcher]::Reorder($physName)
                if ($r -eq 'ok:reordered') { Write-Log ('reorder -> ' + $r); Start-Sleep -Milliseconds 1200 }
                if (((Get-Date) - $lastBlob).TotalMinutes -gt 10) { if (Save-Blob) { $lastBlob = Get-Date } }
            } else {
                Write-Log 'KVM client detected -> duplicated desktop'
                if (Enter-Clone) { $lastState = ''; $lastBlob = Get-Date; $cloneSince = Get-Date }
            }
        }
        elseif ($watching -eq $false) {
            if ($count -ge 2 -and $cfg.revertToSoloWhenIdle) {
                $misses++
                $dwell = ((Get-Date) - $cloneSince).TotalSeconds
                if ($misses -ge $missLimit -and $dwell -ge $dwellSec) {
                    Write-Log ("KVM client gone (misses=$misses, dwell=${dwell}s) -> single screen")
                    if (Save-Blob) { $lastBlob = Get-Date }
                    Enter-Solo
                    $lastState = ''
                    $misses = 0
                }
            }
        }
        else {
            # KVM unreachable: keep the current topology, never switch blind.
            $misses = 0
        }
    }
    catch {
        Write-Log ('loop error: ' + $_.Exception.Message) 'ERROR'
    }
    Start-Sleep -Seconds $pollSec
}
