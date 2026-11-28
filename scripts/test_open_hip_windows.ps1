# Run against an imported HEGo project and a licensed Houdini desktop installation.
param(
    [Parameter(Mandatory)] [string] $GodotConsole,
    [string] $Project = (Join-Path $PSScriptRoot '../demo')
)
$ErrorActionPreference = 'Stop'
$GodotConsole = (Resolve-Path -LiteralPath $GodotConsole).Path
if (-not $GodotConsole.EndsWith('_console.exe', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Pass the Windows Godot _console.exe launcher to exercise its child-process job.'
}
$Project = (Resolve-Path -LiteralPath $Project).Path
$staging = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build/test-staging'))
$work = Join-Path $staging ('open HIP ' + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($work)
$script = Join-Path $work 'open.gd'
$result = Join-Path $work 'snapshot.txt'
$log = Join-Path $work 'godot.log'
$houdini = $null
$godot = $null
try {
    @'
extends SceneTree

func _initialize() -> void:
    run.call_deferred()

func run() -> void:
    var api := HEGoAPI.get_singleton()
    if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "open_hip_%s" % OS.get_process_id()):
        push_error("Could not start a private Houdini Engine session")
        quit(1)
        return
    var panel = load("res://addons/hego/hego_control.tscn").instantiate()
    root.add_child(panel)
    panel.get_node("TabContainer").current_tab = 0
    panel.open_hip_button.pressed.emit()
    while panel._saving_hip:
        await process_frame
    for task: HEGoTask in api.get_completed_task_history():
        if task.get_description() == "Open HIP File" and task.get_status() == HEGoTask.COMPLETED:
            var result := FileAccess.open(OS.get_cmdline_user_args()[0], FileAccess.WRITE)
            result.store_string(task.get_result())
            result.close()
            quit(0)
            return
    push_error("The panel did not open the HIP file")
    quit(1)
'@ | Set-Content -LiteralPath $script -Encoding utf8

    $godot = Start-Process -FilePath $GodotConsole -PassThru -WindowStyle Hidden -ArgumentList @(
        '--headless', '--path', ('"' + $Project + '"'), '--script', ('"' + $script + '"'),
        '--log-file', ('"' + $log + '"'), '--', ('"' + $result + '"')
    ) -Environment @{ TEMP = $work; TMP = $work }
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    while (-not (Test-Path -LiteralPath $result) -and -not $godot.HasExited -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path -LiteralPath $result)) { throw 'Godot failed to open the HIP file.' }
    $wrapperExited = $godot.WaitForExit(15000)
    $snapshot = (Get-Content -Raw -LiteralPath $result).Replace('\', '/')
    if ((Get-Item -LiteralPath $snapshot).Length -eq 0) { throw "Empty HIP file: $snapshot" }
    # Match the unique snapshot before obtaining a process handle for checks and cleanup.
    $owners = @(Get-CimInstance Win32_Process -Filter "Name = 'houdini.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine.Replace('\', '/').Contains($snapshot)
    })
    if ($owners.Count -ne 1) { throw "Houdini did not survive Godot's exit with $snapshot." }
    $houdini = Get-Process -Id $owners[0].ProcessId
    $null = $houdini.Handle
    if (-not $wrapperExited) { throw 'The Godot console launcher is still waiting for Houdini after the editor quit.' }
    if ($godot.ExitCode -ne 0) { throw "Godot exited with code $($godot.ExitCode)." }
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    while ([datetime]::UtcNow -lt $deadline -and -not $houdini.HasExited) {
        $houdini.Refresh()
        if ($houdini.MainWindowTitle.Replace('\', '/').Contains($snapshot)) {
            Write-Output "PASS Houdini opened $snapshot and remained running after Godot exited."
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Houdini did not display the exported scene after Godot exited: $snapshot"
} catch {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
    throw
} finally {
    if ($godot -and -not $godot.HasExited) { $godot.Kill() }
    if ($houdini -and -not $houdini.HasExited) {
        if (-not $houdini.CloseMainWindow() -or -not $houdini.WaitForExit(8000)) {
            $houdini.Kill()
            $houdini.WaitForExit()
        }
    }
    $resolved = (Resolve-Path -LiteralPath $work).Path
    if ([IO.Path]::GetDirectoryName($resolved) -eq $staging) {
        Remove-Item -LiteralPath $resolved -Force -Recurse
    }
}
