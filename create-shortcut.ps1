$ErrorActionPreference = "Stop"

$AppName = "桌面软件助手"
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $BaseDir "desktop_assistant.ps1"
$IconPath = Join-Path $BaseDir "assets\app.ico"

function New-AppShortcut($ShortcutPath) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $shortcut.WorkingDirectory = $BaseDir
    if (Test-Path -LiteralPath $IconPath) {
        $shortcut.IconLocation = "$IconPath,0"
    }
    $shortcut.Description = "打开桌面软件助手"
    $shortcut.Save()
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "$AppName.lnk"
New-AppShortcut $desktopShortcut

$startMenuShortcut = $null
try {
    $programsDir = Join-Path ([Environment]::GetFolderPath("Programs")) $AppName
    if (-not (Test-Path -LiteralPath $programsDir)) {
        New-Item -ItemType Directory -Path $programsDir | Out-Null
    }
    $startMenuShortcut = Join-Path $programsDir "$AppName.lnk"
    New-AppShortcut $startMenuShortcut
} catch {
    Write-Host "开始菜单快捷方式创建失败：$($_.Exception.Message)"
}

Write-Host "已创建快捷方式："
Write-Host "  $desktopShortcut"
if ($startMenuShortcut) {
    Write-Host "  $startMenuShortcut"
}
Write-Host ""
Write-Host "固定到任务栏：右键桌面或开始菜单里的“桌面软件助手”快捷方式，选择“固定到任务栏”。"
Write-Host "取消固定：右键任务栏上的图标，选择“从任务栏取消固定”。"


