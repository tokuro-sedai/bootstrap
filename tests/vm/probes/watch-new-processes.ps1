# Probe: print every NEW process (with parent PID and command line) for 45s.
# Start it with vmctl.py exec, then trigger the thing under test in a user window.
# Shows exactly what a CLI spawns, e.g. whether 'claude auth login' starts rundll32 to open the browser.
# (Process-start WMI traces need admin; the guest exec session isn't elevated.)

# Record every NEW process (any name) and its parent; report those descending from claude.
$base = @{}; Get-Process | ForEach-Object { $base[$_.Id] = 1 }
$info = @{}
$end = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $end) {
    foreach ($p in @(Get-Process)) {
        if (-not $base.ContainsKey($p.Id)) {
            $base[$p.Id] = 1
            $w = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
            $info[$p.Id] = $w
            $par = if ($w) { $w.ParentProcessId } else { '?' }
            "NEW $($p.ProcessName) pid=$($p.Id) ppid=$par cmd=$(if ($w -and $w.CommandLine) { $w.CommandLine.Substring(0, [Math]::Min(200, $w.CommandLine.Length)) })"
        }
    }
    Start-Sleep -Milliseconds 100
}
'WATCH-DONE'
