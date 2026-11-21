# Probe: which ways of opening a URL produce a browser window from THIS window?
# Run in a real user window: vmctl.py launch --name methods --script tests/vm/probes/browser-open-methods.ps1 --wait
# Caveat: Edge relaunches itself after Stop-Process, and a URL sent to a running Edge opens a tab
# with no new process. Treat 'windows 0' as a hint, and confirm with gshot.

function Test-Open([string]$label, [scriptblock]$how) {
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 4
    try { & $how } catch { "$label THREW: $($_.Exception.Message)" }
    Start-Sleep 20
    $e = @(Get-Process msedge -ErrorAction SilentlyContinue)
    "$label -> edge procs $($e.Count), windows $(@($e | Where-Object { $_.MainWindowHandle -ne 0 }).Count)"
}
$u = 'https://example.com'
"BROWSER env: [$env:BROWSER]  GH_BROWSER: [$env:GH_BROWSER]"
Test-Open 'ps-start-process'  { Start-Process $u }
Test-Open 'cmd-start'         { cmd /c start '""' $u }
Test-Open 'rundll32'          { rundll32 url.dll,FileProtocolHandler $u }
Test-Open 'explorer-url'      { explorer.exe $u }
Test-Open 'ps-child-start'    { powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Start '$u'" }
Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
'METHODS-DONE'
