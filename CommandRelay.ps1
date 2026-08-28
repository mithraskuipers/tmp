<#
=====================================================================
 CommandRelay.ps1
=====================================================================
 Runs quietly in the background and listens for two GLOBAL hotkeys
 (they work even while a different application is focused):

   [Toggle hotkey]  -> Start / stop the capture loop.
                       When STARTING:
                         1. You are asked to CLICK the window you
                            want CommandRelay to operate on. A small
                            status banner in the top-left corner of
                            the screen tells you it's waiting for
                            the click (press Esc to cancel instead).
                         2. The window you clicked is identified and
                            a Yes/No confirmation box shows its title.
                            Press Enter (or click Yes) to accept it,
                            or No to click a different window.
                         3. You are asked for a filename - that
                            becomes the .txt file the clipboard data
                            gets appended to for this session.
                            Cancelling this prompt cancels the start
                            (nothing runs).
                       Once running, it repeatedly:
                         1. Brings the selected window to the
                            foreground and sends it CTRL+C
                         2. Waits briefly for the clipboard to update
                         3. Appends the clipboard text to the chosen
                            file
                         4. Brings the selected window to the
                            foreground again and sends the configured
                            ACTION KEY (default F8)
                         5. Waits briefly, then repeats from step 1
                       While running, a small status overlay in the
                       top-left corner of the screen shows which of
                       these steps is currently happening.

   [Exit hotkey]    -> Fully quits this script

 Duplicate-capture protection: each capture is compared to the one
 immediately before it. If they come back 99.5% identical (default;
 configurable), that usually means the target app has stopped handing
 back new data (e.g. you've reached the end of a list). The loop pauses,
 shows a Continue / Stop Capture dialog, and waits for you - it will not
 silently keep looping and appending duplicate content forever. Choosing
 Continue won't re-prompt every cycle; it only asks again once new,
 different content shows up and then goes stale again.

 All settings - default log location, timing, the action key, both
 hotkeys, duplicate-capture detection, and how many rows to skip at the
 start/end of each capture (e.g. to drop a repeated header/footer row a
 target app always copies along with the data) - are read from
 RelayConfig.json (same folder as this script). Use ConfigGUI.ps1 (or
 the "ConfigureCommandRelay.bat" launcher) to change them without
 editing this file. If RelayConfig.json doesn't exist yet, a default
 one is created automatically on first run.

 IMPORTANT:
   - Must run in STA mode (needed for clipboard access). The
     included .bat launcher already starts it with -STA.
   - Because the loop now re-focuses your chosen window itself
     before every action, you no longer have to babysit window
     focus by hand - just make sure that window still exists.
     If it gets closed, the capture stops automatically.
=====================================================================
#>

$ConfigPath = Join-Path $PSScriptRoot "RelayConfig.json"

function Get-DefaultConfig {
    [pscustomobject]@{
        LogFile               = "CapturedOutput.txt"
        CopyDelayMs           = 150
        AfterActionKeyDelayMs = 150
        TimerTickMs           = 50
        SkipRowsStart         = 0
        SkipRowsEnd           = 0
        ActionKeyDisplay      = "F8"
        ActionKeyToken        = "{F8}"
        DupDetectEnabled      = $true
        DupDetectThreshold    = 0.995   # 99.5%
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

if ($Config.PSObject.Properties.Name -contains 'SkipRowsStart') {
    $SkipRowsStart = [int]$Config.SkipRowsStart
} else {
    $SkipRowsStart = 0
}
if ($Config.PSObject.Properties.Name -contains 'SkipRowsEnd') {
    $SkipRowsEnd = [int]$Config.SkipRowsEnd
} else {
    $SkipRowsEnd = 0
}

if ($Config.PSObject.Properties.Name -contains 'DupDetectEnabled') {
    $DupDetectEnabled = [bool]$Config.DupDetectEnabled
} else {
    $DupDetectEnabled = $true
}
if ($Config.PSObject.Properties.Name -contains 'DupDetectThreshold') {
    $DupDetectThreshold = [double]$Config.DupDetectThreshold
} else {
    $DupDetectThreshold = 0.995
}
if ($DupDetectThreshold -gt 1) { $DupDetectThreshold = $DupDetectThreshold / 100.0 }  # tolerate "99.5" as well as "0.995"

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

# ---- Native/custom types: window-focus helpers, the hidden hotkey host
# window, and the top-left status overlay window. All compiled in one
# block so they share the same assembly. ----
$formSource = @"
using System;
using System.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class Win32
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(System.Drawing.Point pt);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int MessageBoxW(IntPtr hWnd, string lpText, string lpCaption, uint uType);
}

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

public class StatusOverlay : Form
{
    protected override bool ShowWithoutActivation
    {
        get { return true; }
    }

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_NOACTIVATE = 0x08000000;
            const int WS_EX_TOOLWINDOW = 0x00000080;
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }
}
"@

Add-Type -TypeDefinition $formSource -ReferencedAssemblies "System.Windows.Forms", "System.Drawing"

# Must be set before ANY Windows Forms control is created on this thread
# (including the filename-prompt dialog and the hidden hotkey form below) -
# .NET throws "Thread exception mode cannot be changed once any Controls
# are created on the thread" if this runs any later. Defining the types
# above does not create any controls, so this can safely come after them.
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
    $consoleHandle = (Get-Process -Id $PID).MainWindowHandle
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [Win32]::ShowWindowAsync($consoleHandle, 6) | Out-Null  # 6 = SW_MINIMIZE
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

# Drops the first $SkipStart and last $SkipEnd rows from one captured
# clipboard chunk before it's written to the log. Used to strip off
# headers/footers that a target app includes with every Ctrl+C (e.g.
# a column header row and a totals row). Returns '' when there aren't
# enough rows left after skipping - the caller should then write
# nothing for that cycle rather than an empty line.
function Get-FilteredCaptureText {
    param(
        [string]$Text,
        [int]$SkipStart,
        [int]$SkipEnd
    )

    if ($SkipStart -le 0 -and $SkipEnd -le 0) { return $Text }
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    # Split on any line-ending style so this works regardless of what
    # the source app puts on the clipboard.
    $lines = $Text -split "`r`n|`r|`n"

    # A trailing empty element shows up when the text ends with a line
    # break - drop it so it isn't counted as an extra "row".
    if ($lines.Length -gt 1 -and $lines[$lines.Length - 1] -eq '') {
        $lines = $lines[0..($lines.Length - 2)]
    }

    $total = $lines.Length
    $start = [Math]::Max(0, $SkipStart)
    $end   = [Math]::Max(0, $SkipEnd)

    if ($start + $end -ge $total) { return '' }

    $keep = $lines[$start..($total - $end - 1)]
    return ($keep -join [Environment]::NewLine)
}

# Compares two captured text blocks and returns how much they overlap, as
# a fraction from 0.0 (nothing in common) to 1.0 (identical). Works line
# by line (matching the row-oriented nature of the row-skip feature above)
# using a multiset intersection, so it stays accurate even if a couple of
# rows shifted position between captures, and stays fast regardless of
# capture size. Used to detect a capture loop that's stuck copying the
# same content over and over (e.g. the target app reached the end of its
# data and stopped producing anything new).
function Get-TextSimilarity {
    param(
        [string]$A,
        [string]$B
    )

    if ([string]::IsNullOrEmpty($A) -and [string]::IsNullOrEmpty($B)) { return 1.0 }
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return 0.0 }
    if ($A -eq $B) { return 1.0 }

    $linesA = $A -split "`r`n|`r|`n"
    $linesB = $B -split "`r`n|`r|`n"

    $countA = @{}
    foreach ($l in $linesA) {
        if ($countA.ContainsKey($l)) { $countA[$l]++ } else { $countA[$l] = 1 }
    }

    $matched = 0
    foreach ($l in $linesB) {
        if ($countA.ContainsKey($l) -and $countA[$l] -gt 0) {
            $countA[$l]--
            $matched++
        }
    }

    $totalMax = [Math]::Max($linesA.Length, $linesB.Length)
    if ($totalMax -eq 0) { return 1.0 }
    return [double]$matched / [double]$totalMax
}

# Small modal prompt shown each time a capture session is started.
# Returns the trimmed filename the user typed, or $null if cancelled.
function Show-FilenamePrompt {
    param(
        [string]$DefaultName,
        [string]$TargetTitle
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Start Capture"
    # ClientSize (not Size) so the title bar/border chrome doesn't eat
    # into the usable area - that was clipping the bottom of the Start
    # Capture/Cancel buttons.
    $dlg.ClientSize      = New-Object System.Drawing.Size(370, 140)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.TopMost         = $true

    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = "Target window: $TargetTitle"
    $lblTarget.Location = New-Object System.Drawing.Point(15, 12)
    $lblTarget.Size = New-Object System.Drawing.Size(340, 18)
    $lblTarget.Font = New-Object System.Drawing.Font($lblTarget.Font, [System.Drawing.FontStyle]::Italic)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Enter a filename for this capture (no extension needed):"
    $lbl.Location = New-Object System.Drawing.Point(15, 38)
    $lbl.Size = New-Object System.Drawing.Size(340, 20)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(15, 62)
    $txt.Size = New-Object System.Drawing.Size(335, 22)
    $txt.Text = $DefaultName
    $txt.SelectAll()

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Start Capture"
    $btnOk.Location = New-Object System.Drawing.Point(170, 98)
    $btnOk.Size = New-Object System.Drawing.Size(115, 28)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(290, 98)
    $btnCancel.Size = New-Object System.Drawing.Size(70, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $dlg.Controls.AddRange(@($lblTarget, $lbl, $txt, $btnOk, $btnCancel))
    $dlg.Add_Shown({ $txt.Focus(); $txt.SelectAll() })

    $result = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $name = $txt.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return $name
}

# Invisible/off-screen host window - only needed so Windows has something
# to deliver the WM_HOTKEY messages to.
$form = New-Object HotkeyForm
$form.ShowInTaskbar   = $false
$form.FormBorderStyle = 'FixedToolWindow'
$form.StartPosition   = 'Manual'
$form.Location        = New-Object System.Drawing.Point(-2000, -2000)
$form.Size            = New-Object System.Drawing.Size(1, 1)
$form.Opacity         = 0

# Save the handle now, while the form is alive - Application.Exit() closes
# and disposes the form before the cleanup code below runs, so re-reading
# $form.Handle at that point no longer returns a valid IntPtr.
$FormHandle = $form.Handle

if (-not [HotkeyForm]::RegisterHotKey($FormHandle, $ToggleHotkeyId, $ToggleModifiers, $ToggleKey)) {
    Write-Host "Failed to register the TOGGLE hotkey ($ToggleDisplay). It may already be in use by another app." -ForegroundColor Red
}
if (-not [HotkeyForm]::RegisterHotKey($FormHandle, $ExitHotkeyId, $ExitModifiers, $ExitKey)) {
    Write-Host "Failed to register the EXIT hotkey ($ExitDisplay). It may already be in use by another app." -ForegroundColor Red
}

# ---- Top-left status overlay: a tiny always-on-top banner that never
# steals keyboard focus (StatusOverlay overrides ShowWithoutActivation
# and adds WS_EX_NOACTIVATE), so showing/updating it never interrupts
# whatever window the automation is currently sending keys to. ----
$statusForm = New-Object StatusOverlay
$statusForm.FormBorderStyle = 'None'
$statusForm.StartPosition   = 'Manual'
$statusForm.ShowInTaskbar   = $false
$statusForm.TopMost         = $true
$statusForm.BackColor       = [System.Drawing.Color]::Black
$statusForm.Opacity         = 0.85
$statusForm.Size            = New-Object System.Drawing.Size(320, 32)

$screenArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$statusForm.Location = New-Object System.Drawing.Point(($screenArea.Left + 8), ($screenArea.Top + 8))

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock      = 'Fill'
$statusLabel.TextAlign = 'MiddleCenter'
$statusLabel.ForeColor = [System.Drawing.Color]::Lime
$statusLabel.Font      = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
$statusLabel.Text      = ''
$statusForm.Controls.Add($statusLabel)

# Force the overlay's handle to exist now (so Select-TargetWindow can
# compare clicked windows against it) without actually showing it yet.
[void]$statusForm.Handle
$statusForm.Hide()

function Set-RelayStatus {
    param(
        [string]$Text,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Lime
    )
    $statusLabel.ForeColor = $Color
    $statusLabel.Text      = $Text
    if (-not $statusForm.Visible) { $statusForm.Show() }
}

function Hide-RelayStatus {
    $statusForm.Hide()
}

# ---- Window picking: user clicks a window, we identify it, then a
# Yes/No dialog (Enter = Yes) confirms it before anything starts. ----
function Select-TargetWindow {
    Set-RelayStatus "Click the target window... (Esc to cancel)" ([System.Drawing.Color]::Yellow)
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Cross

    $VK_LBUTTON = 0x01
    $VK_ESCAPE  = 0x1B
    $picked     = [IntPtr]::Zero

    while ($true) {
        Start-Sleep -Milliseconds 15
        [System.Windows.Forms.Application]::DoEvents()

        if (([Win32]::GetAsyncKeyState($VK_ESCAPE) -band 0x8000) -ne 0) {
            $picked = [IntPtr]::Zero
            break
        }

        if (([Win32]::GetAsyncKeyState($VK_LBUTTON) -band 0x8000) -ne 0) {
            $pt   = [System.Windows.Forms.Cursor]::Position
            $hwnd = [Win32]::WindowFromPoint($pt)
            $root = [Win32]::GetAncestor($hwnd, [uint32]2)   # GA_ROOT

            # Wait for the click to release before deciding anything, so
            # only one deliberate click is ever consumed here.
            while (([Win32]::GetAsyncKeyState($VK_LBUTTON) -band 0x8000) -ne 0) {
                Start-Sleep -Milliseconds 10
                [System.Windows.Forms.Application]::DoEvents()
            }

            if ($root -eq [IntPtr]::Zero -or $root -eq $statusForm.Handle) {
                continue   # clicked on our own overlay or nothing useful - keep waiting
            }
            $picked = $root
            break
        }
    }

    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default

    if ($picked -eq [IntPtr]::Zero) { return $null }

    $sb = New-Object System.Text.StringBuilder 256
    [void][Win32]::GetWindowText($picked, $sb, $sb.Capacity)
    $title = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "(untitled window)" }

    return [pscustomobject]@{ Handle = $picked; Title = $title }
}

function Confirm-TargetWindow {
    param([string]$Title)
    $msg = "Target window identified:`n`n$Title`n`nIs this correct?"

    # Using the raw Win32 MessageBoxW (instead of
    # [System.Windows.Forms.MessageBox]::Show) so we can pass
    # MB_SETFOREGROUND/MB_TOPMOST - this is what's triggered from a
    # global hotkey handler, so there is no already-focused WinForms
    # window to make it foreground/active. Without these flags the box
    # can appear behind or without keyboard focus, forcing a mouse click
    # instead of just pressing Enter for the (still) default Yes button.
    $MB_YESNO         = 0x00000004
    $MB_ICONQUESTION  = 0x00000020
    $MB_DEFBUTTON1    = 0x00000000
    $MB_TOPMOST       = 0x00040000
    $MB_SETFOREGROUND = 0x00010000
    $flags = $MB_YESNO -bor $MB_ICONQUESTION -bor $MB_DEFBUTTON1 -bor $MB_TOPMOST -bor $MB_SETFOREGROUND

    $IDYES = 6
    $result = [Win32]::MessageBoxW([IntPtr]::Zero, $msg, "Confirm Target Window", [uint32]$flags)
    return ($result -eq $IDYES)
}

# Shown when back-to-back captures come back nearly identical. Returns
# 'Continue' or 'Stop'.
function Show-DuplicateCapturePrompt {
    param(
        [double]$Similarity,
        [string]$TargetTitle
    )

    $pct = [Math]::Round($Similarity * 100, 2)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Duplicate Capture Detected"
    $dlg.Size            = New-Object System.Drawing.Size(430, 190)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.TopMost         = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "The last two captures from `"$TargetTitle`" are $pct% identical.`n`nThis usually means the target app has stopped producing new data (e.g. you've reached the end of a list). Continue capturing anyway, or stop here?"
    $lbl.Location = New-Object System.Drawing.Point(15, 12)
    $lbl.Size = New-Object System.Drawing.Size(395, 100)

    $btnContinue = New-Object System.Windows.Forms.Button
    $btnContinue.Text = "Continue"
    $btnContinue.Location = New-Object System.Drawing.Point(140, 118)
    $btnContinue.Size = New-Object System.Drawing.Size(125, 30)
    $btnContinue.DialogResult = [System.Windows.Forms.DialogResult]::Yes

    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = "Stop Capture"
    $btnStop.Location = New-Object System.Drawing.Point(275, 118)
    $btnStop.Size = New-Object System.Drawing.Size(125, 30)
    $btnStop.DialogResult = [System.Windows.Forms.DialogResult]::No

    $dlg.AcceptButton = $btnContinue
    $dlg.CancelButton = $btnStop
    $dlg.Controls.AddRange(@($lbl, $btnContinue, $btnStop))

    $result = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { return 'Continue' }
    return 'Stop'
}

# Fully resets every piece of session state to "off". Used by both the
# manual toggle-off and the duplicate-capture "Stop" choice, so a new
# session started afterwards always begins from the same clean slate
# instead of possibly inheriting stale state (leftover State/elapsed
# counters, a suppressed duplicate-warning flag, the previous capture's
# text, etc.) from however the previous session ended.
function Stop-RelayCapture {
    $timer.Stop()
    $global:CR_Running            = $false
    $global:CR_State              = 'Idle'
    $global:CR_ElapsedMs          = 0
    $global:CR_PrevCaptureText    = $null
    $global:CR_SuppressDupWarning = $false
    $global:CR_TargetHandle       = [IntPtr]::Zero
    Hide-RelayStatus
}

# Brings the target window to the foreground before an automated key is
# sent to it. Returns $false if the window no longer exists.
function Set-RelayForeground {
    param([IntPtr]$Handle)

    if ($Handle -eq [IntPtr]::Zero) { return $true }
    if (-not [Win32]::IsWindow($Handle)) { return $false }

    if ([Win32]::IsIconic($Handle)) {
        [void][Win32]::ShowWindow($Handle, 9)   # SW_RESTORE
    }

    if ([Win32]::GetForegroundWindow() -ne $Handle) {
        [void][Win32]::SetForegroundWindow($Handle)

        if ([Win32]::GetForegroundWindow() -ne $Handle) {
            # Windows normally blocks a background process from stealing
            # foreground focus outright. Tapping Alt first is a long-
            # standing, widely used workaround that "unlocks"
            # SetForegroundWindow for the very next call.
            [Win32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)  # Alt down
            [Win32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)  # Alt up
            [void][Win32]::SetForegroundWindow($Handle)
        }
    }

    Start-Sleep -Milliseconds 30
    return $true
}

Write-Host "CommandRelay is running." -ForegroundColor White
Write-Host "  $ToggleDisplay  -> start/stop the capture loop" -ForegroundColor White
Write-Host "                    (click a window to target, confirm it, then name the file)"
Write-Host "  $ExitDisplay  -> quit"
Write-Host "Action key: $ActionKeyDisplay"
Write-Host "Log folder: $LogDir"
Write-Host "Config:     $ConfigPath"
if ($SkipRowsStart -gt 0 -or $SkipRowsEnd -gt 0) {
    Write-Host "Row filter: skipping first $SkipRowsStart and last $SkipRowsEnd row(s) of each capture"
}
if ($DupDetectEnabled) {
    Write-Host "Duplicate-capture protection: ON (pauses to ask at $([Math]::Round($DupDetectThreshold * 100, 2))% overlap with the previous capture)"
} else {
    Write-Host "Duplicate-capture protection: OFF"
}
Write-Host ""

$global:CR_Running      = $false
$global:CR_Selecting    = $false
$global:CR_State        = 'Idle'   # Idle -> PostCopy -> PostAction -> Idle ...
$global:CR_ElapsedMs    = 0
$global:CR_LogFile      = $DefaultLogFile
$global:CR_TargetHandle = [IntPtr]::Zero
$global:CR_TargetTitle  = ''
$global:CR_PrevCaptureText     = $null
$global:CR_SuppressDupWarning  = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $TimerTickMs

$tickAction = {
    if (-not $global:CR_Running) { return }

    try {
        switch ($global:CR_State) {
            'Idle' {
                if (-not (Set-RelayForeground -Handle $global:CR_TargetHandle)) {
                    Write-Host "[CommandRelay] Target window is gone - stopping capture." -ForegroundColor Red
                    Stop-RelayCapture
                    return
                }
                Set-RelayStatus "-> $($global:CR_TargetTitle) : Copying (Ctrl+C)" ([System.Drawing.Color]::Lime)
                [System.Windows.Forms.SendKeys]::SendWait('^c')
                $global:CR_State     = 'PostCopy'
                $global:CR_ElapsedMs = 0
            }
            'PostCopy' {
                $global:CR_ElapsedMs += $TimerTickMs
                if ($global:CR_ElapsedMs -ge $CopyDelayMs) {
                    $stopRequested = $false
                    try {
                        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                            $text = [System.Windows.Forms.Clipboard]::GetText()

                            # ---- Duplicate-capture check: compare this
                            # capture against the immediately previous one.
                            # If they're near-identical, the target app has
                            # likely stopped producing new data - pause and
                            # let the user decide whether to keep going. ----
                            if ($DupDetectEnabled -and $null -ne $global:CR_PrevCaptureText) {
                                $similarity = Get-TextSimilarity -A $global:CR_PrevCaptureText -B $text
                                if ($similarity -ge $DupDetectThreshold) {
                                    if (-not $global:CR_SuppressDupWarning) {
                                        $timer.Stop()
                                        $pct = [Math]::Round($similarity * 100, 2)
                                        Set-RelayStatus "-> $($global:CR_TargetTitle) : Duplicate capture ($pct% match)" ([System.Drawing.Color]::Yellow)
                                        Write-Host "[CommandRelay] Duplicate capture detected ($pct% match with the previous one)." -ForegroundColor Yellow

                                        $choice = Show-DuplicateCapturePrompt -Similarity $similarity -TargetTitle $global:CR_TargetTitle
                                        if ($choice -eq 'Stop') {
                                            Stop-RelayCapture
                                            Write-Host "[CommandRelay] Capture STOPPED (duplicate content confirmed by user)." -ForegroundColor Cyan
                                            $stopRequested = $true
                                        } else {
                                            # Don't nag again every single cycle - only re-arm once a
                                            # genuinely different capture comes in (see the 'else' below).
                                            $global:CR_SuppressDupWarning = $true
                                            Write-Host "[CommandRelay] Continuing despite duplicate content (won't ask again until new content appears)." -ForegroundColor Yellow
                                        }

                                        if ($global:CR_Running) { $timer.Start() }
                                    }
                                } else {
                                    $global:CR_SuppressDupWarning = $false
                                }
                            }

                            $global:CR_PrevCaptureText = $text

                            if (-not $stopRequested) {
                                $filtered = Get-FilteredCaptureText -Text $text -SkipStart $SkipRowsStart -SkipEnd $SkipRowsEnd
                                if (-not [string]::IsNullOrEmpty($filtered)) {
                                    Add-Content -Path $global:CR_LogFile -Value $filtered
                                }
                            }
                        }
                    } catch {
                        Write-Host "Clipboard read failed: $_" -ForegroundColor Yellow
                    }

                    if ($stopRequested) { return }

                    if (-not (Set-RelayForeground -Handle $global:CR_TargetHandle)) {
                        Write-Host "[CommandRelay] Target window is gone - stopping capture." -ForegroundColor Red
                        Stop-RelayCapture
                        return
                    }
                    Set-RelayStatus "-> $($global:CR_TargetTitle) : Sending $ActionKeyDisplay" ([System.Drawing.Color]::Orange)
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
        if ($global:CR_Selecting) { return }   # ignore repeat presses mid-selection

        if (-not $global:CR_Running) {
            $global:CR_Selecting = $true
            try {
                # 1. Click-to-pick the target window, with a Yes/No
                #    identify-and-confirm step (Enter = Yes).
                $target = $null
                while ($true) {
                    $picked = Select-TargetWindow
                    if ($null -eq $picked) {
                        Write-Host "[CommandRelay] Capture start cancelled (no window selected)." -ForegroundColor Yellow
                        Hide-RelayStatus
                        return
                    }
                    if (Confirm-TargetWindow -Title $picked.Title) {
                        $target = $picked
                        break
                    }
                    Write-Host "[CommandRelay] Selection rejected - click the correct window." -ForegroundColor Yellow
                }

                # 2. Ask for the filename, same as before, then start
                #    right away once Enter is pressed.
                $name = Show-FilenamePrompt -DefaultName $DefaultBaseName -TargetTitle $target.Title
                if ($null -eq $name) {
                    Write-Host "[CommandRelay] Capture start cancelled." -ForegroundColor Yellow
                    Hide-RelayStatus
                    return
                }
                $safeName = Get-SafeFileName $name
                if (-not $safeName.ToLower().EndsWith('.txt')) { $safeName += '.txt' }

                $global:CR_LogFile      = Join-Path $LogDir $safeName
                $global:CR_TargetHandle = $target.Handle
                $global:CR_TargetTitle  = $target.Title
                $global:CR_Running      = $true
                $global:CR_State        = 'Idle'
                $global:CR_ElapsedMs    = 0
                $global:CR_PrevCaptureText    = $null
                $global:CR_SuppressDupWarning = $false

                # Stop then Start (rather than just Start) so the timer's
                # own interval countdown always begins fresh for this new
                # session, regardless of whatever state - running, stopped
                # via duplicate-detection, stopped manually - it was left
                # in by the previous one.
                $timer.Stop()
                $timer.Start()

                Write-Host "[CommandRelay] Capture STARTED -> $($global:CR_LogFile)" -ForegroundColor Green
                Write-Host "[CommandRelay] Target window -> $($target.Title)" -ForegroundColor Green
                Set-RelayStatus "-> $($target.Title) : starting..." ([System.Drawing.Color]::Lime)
            } finally {
                $global:CR_Selecting = $false
            }
        } else {
            Stop-RelayCapture
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
[HotkeyForm]::UnregisterHotKey($FormHandle, $ToggleHotkeyId) | Out-Null
[HotkeyForm]::UnregisterHotKey($FormHandle, $ExitHotkeyId)   | Out-Null
$statusForm.Dispose()
Write-Host "CommandRelay stopped."
