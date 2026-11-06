# Registers GlkvmScreenSwitcher as a logon scheduled task.
# Run from an elevated PowerShell if the task does not start for your user.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'GLKVM Screen Switcher'
$vbs = Join-Path $root 'run-hidden.vbs'
$cfg = Join-Path $root 'config.json'
$example = Join-Path $root 'config.example.json'

if (-not (Test-Path $cfg)) {
    Copy-Item $example $cfg
    Write-Host "config.json created from config.example.json - edit it before the task will work:" -ForegroundColor Yellow
    Write-Host "  $cfg"
}
if (-not (Test-Path $vbs)) { throw "missing $vbs" }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"') -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Switches the display topology when a GLKVM/PiKVM client connects.' | Out-Null

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
Write-Host ("task '{0}' registered, state={1}" -f $taskName, (Get-ScheduledTask -TaskName $taskName).State)
