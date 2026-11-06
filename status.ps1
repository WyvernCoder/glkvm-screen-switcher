# Quick status: display topology, KVM client state, HDR state, last log lines.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $root 'GlkvmScreenSwitcher.ps1'
$log = Join-Path $root 'logs\switcher.log'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Mode status

$t = Get-ScheduledTask -TaskName 'GLKVM Screen Switcher' -ErrorAction SilentlyContinue
Write-Host ("task     : " + $(if ($t) { $t.State.ToString() } else { 'not installed' }))
$proc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*-File*GlkvmScreenSwitcher.ps1*' -and $_.ProcessId -ne $PID }
Write-Host ("process  : " + $(if ($proc) { "pid $($proc.ProcessId)" } else { 'not running' }))

if (Test-Path $log) {
    Write-Host "`nlast log lines:"
    Get-Content $log -Tail 12
}
