# Removes the scheduled task and stops the switcher.
$ErrorActionPreference = 'Continue'
$taskName = 'GLKVM Screen Switcher'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*GlkvmScreenSwitcher.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host 'switcher removed'
