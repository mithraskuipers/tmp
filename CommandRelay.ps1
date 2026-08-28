<#
=====================================================================
 CommandRelay.ps1
=====================================================================
 Runs quietly in the background and listens for two GLOBAL hotkeys
 (they work even while a different application is focused):

   [Toggle hotkey]  -> Start / stop the capture loop.
                       When STARTING, a small prompt first asks you
                       to type a filename - that becomes the .txt
                       file the clipboard data gets appended to for
                       this session. Cancelling the prompt cancels
                       the start (nothing runs).
                       While ON, it repeatedly:
                         1. Sends CTRL+C to whatever window is focused
                         2. Waits briefly for the clipboard to update
                         3. Appends the clipboard text to the chosen file
                         4. Sends the configured ACTION KEY (default F8)
                         5. Waits briefly, then repeats from step 1

   [Exit hotkey]    -> Fully quits this script

 All settings - default log location, timing, the action key, and
 both hotkeys - are read from RelayConfig.json (same folder as this
 script). Use ConfigGUI.ps1 (or the "ConfigureCommandRelay.bat"
 launcher) to change them without editing this file. If
 RelayConfig.json doesn't exist yet, a default one is created
 automatically on first run.

 IMPORTANT:
   - Must run in STA mode (needed for clipboard access). The
     included .bat launcher already starts it with -STA.
   - Make sure the OTHER application is the focused/active window
     before you press the toggle hotkey - keystrokes go to whatever
     window currently has focus, not to this script. When the
     filename prompt appears, focus moves to it temporarily; typing
     a name and pressing Enter (or clicking Start Capture) hands
     focus back and the loop begins.
=====================================================================
#>

$ConfigPath = Join-Path $PSScriptRoot "RelayConfig.json"

function Get-DefaultConfig {
    [pscustomobject]@{
        LogFile               = "CapturedOutput.txt"
        CopyDelayMs           = 150
        AfterActionKeyDelayMs = 150
        TimerTickMs           = 50
        ActionKeyDisplay      = "F8"
        ActionKeyToken        = "{F8}"
        ToggleHotkey          = [pscustomobject]@{ Modifiers = 3; Key = 0x43; Display = "Ctrl+Alt+C" }  # Ctrl+Alt+C
        ExitHotkey            = [pscustomobject]@{ Modifiers = 3; Key = 0x58; Display = "Ctrl+Alt+X" }  # Ctrl+Alt+X
    }
}

if (Test-Path $ConfigPath) {
    try {
        $Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "RelayConfig.json is corrupt or unreadable - falling back to defaults." -ForegroundColor Yellow
        $Config = Get-DefaultConfig
    }
} else {
    $Config = Get-DefaultConfig
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "No config found - created a default RelayConfig.json." -ForegroundColor Yellow
}

# ---- Resolve settings from config (with fallbacks for older config files) ----
$DefaultLogFile = $Config.LogFile
if (-not [System.IO.Path]::IsPathRooted($DefaultLogFile)) {
    $DefaultLogFile = Join-Path $PSScriptRoot $DefaultLogFile
}
$LogDir             = Split-Path -Path $DefaultLogFile -Parent
$DefaultBaseName    = [System.IO.Path]::GetFileNameWithoutExtension($DefaultLogFile)

$CopyDelayMs = [int]$Config.CopyDelayMs
$TimerTickMs = [int]$Config.TimerTickMs

if ($Config.PSObject.Properties.Name -contains 'AfterActionKeyDelayMs') {
    $AfterActionKeyDelayMs = [int]$Config.AfterActionKeyDelayMs
} elseif ($Config.PSObject.Properties.Name -contains 'AfterF8DelayMs') {
    $AfterActionKeyDelayMs = [int]$Config.AfterF8DelayMs   # old config field name
} else {
    $AfterActionKeyDelayMs = 150
}

if ($Config.PSObject.Properties.Name -contains 'ActionKeyToken') {
    $ActionKeyToken   = [string]$Config.ActionKeyToken
    $ActionKeyDisplay = [string]$Config.ActionKeyDisplay
} else {
    $ActionKeyToken   = '{F8}'
    $ActionKeyDisplay = 'F8'
}

$ToggleHotkeyId  = 1
$ToggleModifiers = [int]$Config.ToggleHotkey.Modifiers
$ToggleKey       = [int]$Config.ToggleHotkey.Key
$ToggleDisplay   = [string]$Config.ToggleHotkey.Display

$ExitHotkeyId    = 2
$ExitModifiers   = [int]$Config.ExitHotkey.Modifiers
$ExitKey         = [int]$Config.ExitHotkey.Key
$ExitDisplay     = [string]$Config.ExitHotkey.Display
# ----------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Must be set before ANY Windows Forms control is created on this thread
# (including the filename-prompt dialog and the hidden hotkey form below) -
# .NET throws "Thread exception mode cannot be changed once any Controls
# are created on the thread" if this runs any later.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-Host "[CommandRelay] Unhandled UI exception (recovered): $($e.Exception.Message)" -ForegroundColor Yellow
})

# Minimize this script's own console window. It sends Ctrl+C to whatever
# window currently has focus - if this console itself ever ends up
# focused (easy to do by accident, e.g. after an Alt-Tab), that Ctrl+C
# goes to PowerShell instead of your target app, which makes PowerShell
# abort the running pipeline ("The pipeline has been stopped."). Keeping
# this window minimized makes that far less likely to happen.
try {
    Add-Type -Name Win32ShowWindow -Namespace CommandRelayNative -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@
    $consoleHandle = (Get-Process -Id $PID).MainWindowHandle
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [CommandRelayNative.Win32ShowWindow]::ShowWindowAsync($consoleHandle, 6) | Out-Null  # 6 = SW_MINIMIZE
    }
} catch {
    # Non-critical - if this fails for any reason, just carry on.
}

function Get-SafeFileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

# Small modal prompt shown each time a capture session is started.
# Returns the trimmed filename the user typed, or $null if cancelled.
function Show-FilenamePrompt {
    param([string]$DefaultName)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Start Capture"
    $dlg.Size            = New-Object System.Drawing.Size(360, 150)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.TopMost         = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Enter a filename for this capture (no extension needed):"
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(320, 20)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(15, 40)
    $txt.Size = New-Object System.Drawing.Size(315, 22)
    $txt.Text = $DefaultName
    $txt.SelectAll()

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Start Capture"
    $btnOk.Location = New-Object System.Drawing.Point(150, 75)
    $btnOk.Size = New-Object System.Drawing.Size(115, 28)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(270, 75)
    $btnCancel.Size = New-Object System.Drawing.Size(70, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $dlg.Controls.AddRange(@($lbl, $txt, $btnOk, $btnCancel))
    $dlg.Add_Shown({ $txt.Focus(); $txt.SelectAll() })

    $result = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $name = $txt.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return $name
}

$formSource = @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class HotkeyForm : Form
{
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public event EventHandler<int> HotkeyPressed;

    private const int WM_HOTKEY = 0x0312;

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            int id = m.WParam.ToInt32();
            if (HotkeyPressed != null) HotkeyPressed(this, id);
        }
        base.WndProc(ref m);
    }
}
"@

Add-Type -TypeDefinition $formSource -ReferencedAssemblies "System.Windows.Forms","System.Drawing"

# Invisible/off-screen host window - only needed so Windows has something
# to deliver the WM_HOTKEY messages to.
$form = New-Object HotkeyForm
$form.ShowInTaskbar   = $false
$form.FormBorderStyle = 'FixedToolWindow'
$form.StartPosition   = 'Manual'
$form.Location        = New-Object System.Drawing.Point(-2000, -2000)
$form.Size            = New-Object System.Drawing.Size(1, 1)
$form.Opacity         = 0

if (-not [HotkeyForm]::RegisterHotKey($form.Handle, $ToggleHotkeyId, $ToggleModifiers, $ToggleKey)) {
    Write-Host "Failed to register the TOGGLE hotkey ($ToggleDisplay). It may already be in use by another app." -ForegroundColor Red
}
if (-not [HotkeyForm]::RegisterHotKey($form.Handle, $ExitHotkeyId, $ExitModifiers, $ExitKey)) {
    Write-Host "Failed to register the EXIT hotkey ($ExitDisplay). It may already be in use by another app." -ForegroundColor Red
}

Write-Host "CommandRelay is running." -ForegroundColor White
Write-Host "  $ToggleDisplay  -> start/stop the capture loop (you'll be asked for a filename each time you start)"
Write-Host "  $ExitDisplay  -> quit"
Write-Host "Action key: $ActionKeyDisplay"
Write-Host "Log folder: $LogDir"
Write-Host "Config:     $ConfigPath"
Write-Host ""

$global:CR_Running   = $false
$global:CR_State     = 'Idle'   # Idle -> PostCopy -> PostAction -> Idle ...
$global:CR_ElapsedMs = 0
$global:CR_LogFile   = $DefaultLogFile

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $TimerTickMs

$tickAction = {
    if (-not $global:CR_Running) { return }

    try {
        switch ($global:CR_State) {
            'Idle' {
                [System.Windows.Forms.SendKeys]::SendWait('^c')
                $global:CR_State     = 'PostCopy'
                $global:CR_ElapsedMs = 0
            }
            'PostCopy' {
                $global:CR_ElapsedMs += $TimerTickMs
                if ($global:CR_ElapsedMs -ge $CopyDelayMs) {
                    try {
                        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                            $text = [System.Windows.Forms.Clipboard]::GetText()
                            Add-Content -Path $global:CR_LogFile -Value $text
                        }
                    } catch {
                        Write-Host "Clipboard read failed: $_" -ForegroundColor Yellow
                    }
                    [System.Windows.Forms.SendKeys]::SendWait($ActionKeyToken)
                    $global:CR_State     = 'PostAction'
                    $global:CR_ElapsedMs = 0
                }
            }
            'PostAction' {
                $global:CR_ElapsedMs += $TimerTickMs
                if ($global:CR_ElapsedMs -ge $AfterActionKeyDelayMs) {
                    $global:CR_State = 'Idle'
                }
            }
        }
    } catch {
        # Covers cases like a stray Ctrl+C landing on this console, which
        # makes PowerShell throw "The pipeline has been stopped." here.
        # Log it and reset to a safe state instead of letting it bubble
        # up and crash the whole app.
        Write-Host "[CommandRelay] Tick error (recovered): $($_.Exception.Message)" -ForegroundColor Yellow
        $global:CR_State     = 'Idle'
        $global:CR_ElapsedMs = 0
    }
}

$timer.Add_Tick($tickAction)
$timer.Start()

$hotkeyAction = {
    param($sender, $id)

    if ($id -eq $ToggleHotkeyId) {
        if (-not $global:CR_Running) {
            # Starting a new session - ask for a filename first.
            $name = Show-FilenamePrompt -DefaultName $DefaultBaseName
            if ($null -eq $name) {
                Write-Host "[CommandRelay] Capture start cancelled." -ForegroundColor Yellow
                return
            }
            $safeName = Get-SafeFileName $name
            if (-not $safeName.ToLower().EndsWith('.txt')) { $safeName += '.txt' }

            $global:CR_LogFile   = Join-Path $LogDir $safeName
            $global:CR_Running   = $true
            $global:CR_State     = 'Idle'
            $global:CR_ElapsedMs = 0
            Write-Host "[CommandRelay] Capture STARTED -> $($global:CR_LogFile)" -ForegroundColor Green
        } else {
            $global:CR_Running = $false
            Write-Host "[CommandRelay] Capture STOPPED" -ForegroundColor Cyan
        }
    }
    elseif ($id -eq $ExitHotkeyId) {
        Write-Host "[CommandRelay] Exiting..." -ForegroundColor Magenta
        [System.Windows.Forms.Application]::Exit()
    }
}

$form.Add_HotkeyPressed($hotkeyAction)

[System.Windows.Forms.Application]::Run($form)

# Cleanup on exit
$timer.Stop()
[HotkeyForm]::UnregisterHotKey($form.Handle, $ToggleHotkeyId) | Out-Null
[HotkeyForm]::UnregisterHotKey($form.Handle, $ExitHotkeyId)   | Out-Null
Write-Host "CommandRelay stopped."
