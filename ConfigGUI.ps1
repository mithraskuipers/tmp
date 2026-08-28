<#
=====================================================================
 ConfigGUI.ps1
=====================================================================
 Simple GUI for editing RelayConfig.json - the settings file used
 by CommandRelay.ps1. Lets you change:

   - The log file path
   - The action key (the button sent after each Ctrl+C - default F8)
   - The delay after Ctrl+C (before reading the clipboard)
   - The delay after the action key (before the next Ctrl+C)
   - The internal poll interval
   - Rows to skip at the start/end of each captured chunk
   - Duplicate-capture detection (pause & ask when back-to-back
     captures come back almost identical, e.g. the target app has
     stopped producing new data)
   - The Toggle hotkey (start/stop capture)
   - The Exit hotkey (quit CommandRelay)

 The two HOTKEYS (Toggle/Exit) are global shortcuts, so Windows
 requires at least one modifier (Ctrl/Alt/Shift) - a bare key like
 "F9" alone isn't accepted for those.

 The ACTION KEY is different: it's just simulated as a keypress
 inside the target application, so it can be a single key with no
 modifier at all (e.g. plain F8), or a modified combo if the target
 app needs one (e.g. Ctrl+F8).

 Changes only take effect the next time CommandRelay.ps1 is started
 (or restarted) - it reads the config once at launch.
=====================================================================
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
        DupDetectThreshold    = 0.995
        ToggleHotkey          = [pscustomobject]@{ Modifiers = 3; Key = 0x43; Display = "Ctrl+Alt+C" }
        ExitHotkey            = [pscustomobject]@{ Modifiers = 3; Key = 0x58; Display = "Ctrl+Alt+X" }
    }
}

# Converts a captured key + modifier bitmask into a SendKeys-compatible
# token, e.g. F8 -> "{F8}", Ctrl+F8 -> "^({F8})", 'a' -> "a".
function Convert-KeyToSendKeysToken {
    param(
        [Parameter(Mandatory)][int]$Vk,
        [Parameter(Mandatory)][int]$Mods
    )

    $key = [System.Windows.Forms.Keys]$Vk
    $name = $key.ToString()

    $specialMap = @{
        'Back'        = '{BACKSPACE}'
        'Tab'         = '{TAB}'
        'Enter'       = '{ENTER}'
        'Return'      = '{ENTER}'
        'Escape'      = '{ESC}'
        'Space'       = ' '
        'PageUp'      = '{PGUP}'
        'Prior'       = '{PGUP}'
        'PageDown'    = '{PGDN}'
        'Next'        = '{PGDN}'
        'End'         = '{END}'
        'Home'        = '{HOME}'
        'Left'        = '{LEFT}'
        'Up'          = '{UP}'
        'Right'       = '{RIGHT}'
        'Down'        = '{DOWN}'
        'Insert'      = '{INSERT}'
        'Delete'      = '{DELETE}'
        'Help'        = '{HELP}'
        'NumLock'     = '{NUMLOCK}'
        'Scroll'      = '{SCROLLLOCK}'
        'CapsLock'    = '{CAPSLOCK}'
        'PrintScreen' = '{PRTSC}'
        'Pause'       = '{BREAK}'
        'Add'         = '{ADD}'
        'Subtract'    = '{SUBTRACT}'
        'Multiply'    = '{MULTIPLY}'
        'Divide'      = '{DIVIDE}'
        'Decimal'     = '{DECIMAL}'
    }

    if ($name -match '^F([0-9]|1[0-9]|2[0-4])$') {
        $baseToken = "{$($name.ToUpper())}"
    }
    elseif ($name -match '^NumPad(\d)$') {
        $baseToken = "{NUMPAD$($Matches[1])}"
    }
    elseif ($specialMap.ContainsKey($name)) {
        $baseToken = $specialMap[$name]
    }
    elseif ($name -match '^D(\d)$') {
        $baseToken = $Matches[1]
    }
    elseif ($name.Length -eq 1) {
        $ch = $name.ToLower()
        if ('+^%~(){}[]' -like "*$ch*") { $baseToken = "{$ch}" } else { $baseToken = $ch }
    }
    else {
        # Best-effort fallback for keys without an explicit mapping above
        $baseToken = "{$($name.ToUpper())}"
    }

    $prefix = ""
    if ($Mods -band 0x0002) { $prefix += '^' }  # Ctrl
    if ($Mods -band 0x0001) { $prefix += '%' }  # Alt
    if ($Mods -band 0x0004) { $prefix += '+' }  # Shift

    if ($prefix -eq "") { return $baseToken }
    return "$prefix($baseToken)"
}

if (Test-Path $ConfigPath) {
    try {
        $existing = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        $existing = Get-DefaultConfig
    }
} else {
    $existing = Get-DefaultConfig
}

$defaultsForFallback = Get-DefaultConfig
if (-not ($existing.PSObject.Properties.Name -contains 'ActionKeyToken')) {
    $existing | Add-Member -NotePropertyName ActionKeyToken   -NotePropertyValue $defaultsForFallback.ActionKeyToken
    $existing | Add-Member -NotePropertyName ActionKeyDisplay -NotePropertyValue $defaultsForFallback.ActionKeyDisplay
}
if (-not ($existing.PSObject.Properties.Name -contains 'AfterActionKeyDelayMs')) {
    $fallbackDelay = if ($existing.PSObject.Properties.Name -contains 'AfterF8DelayMs') { $existing.AfterF8DelayMs } else { $defaultsForFallback.AfterActionKeyDelayMs }
    $existing | Add-Member -NotePropertyName AfterActionKeyDelayMs -NotePropertyValue $fallbackDelay
}
if (-not ($existing.PSObject.Properties.Name -contains 'SkipRowsStart')) {
    $existing | Add-Member -NotePropertyName SkipRowsStart -NotePropertyValue $defaultsForFallback.SkipRowsStart
}
if (-not ($existing.PSObject.Properties.Name -contains 'SkipRowsEnd')) {
    $existing | Add-Member -NotePropertyName SkipRowsEnd -NotePropertyValue $defaultsForFallback.SkipRowsEnd
}
if (-not ($existing.PSObject.Properties.Name -contains 'DupDetectEnabled')) {
    $existing | Add-Member -NotePropertyName DupDetectEnabled -NotePropertyValue $defaultsForFallback.DupDetectEnabled
}
if (-not ($existing.PSObject.Properties.Name -contains 'DupDetectThreshold')) {
    $existing | Add-Member -NotePropertyName DupDetectThreshold -NotePropertyValue $defaultsForFallback.DupDetectThreshold
}

# Working copies of captured key/hotkey state
$script:ToggleMods = [int]$existing.ToggleHotkey.Modifiers
$script:ToggleKey  = [int]$existing.ToggleHotkey.Key
$script:ExitMods   = [int]$existing.ExitHotkey.Modifiers
$script:ExitKey    = [int]$existing.ExitHotkey.Key
$script:ActionMods = 0   # recomputed on capture; not needed for saved default (token already built)
$script:ActionKey  = 0
$script:ActionToken = [string]$existing.ActionKeyToken
$script:Capturing  = $null   # $null, 'Toggle', 'Exit', or 'Action'
$script:PreCaptureText = ""

# ------------------------- Build the form -----------------------------
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "CommandRelay - Configuration"
$form.Size            = New-Object System.Drawing.Size(480, 690)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.KeyPreview      = $true

# --- Log file group ---
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = "Default log location (you'll be asked for a filename each time you start a capture)"
$grpLog.Location = New-Object System.Drawing.Point(15, 15)
$grpLog.Size = New-Object System.Drawing.Size(435, 60)

$txtLogFile = New-Object System.Windows.Forms.TextBox
$txtLogFile.Location = New-Object System.Drawing.Point(15, 25)
$txtLogFile.Size = New-Object System.Drawing.Size(310, 22)
$txtLogFile.Text = $existing.LogFile

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Browse..."
$btnBrowse.Location = New-Object System.Drawing.Point(335, 23)
$btnBrowse.Size = New-Object System.Drawing.Size(85, 25)
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $dlg.Title = "Choose log file location"
    $dlg.OverwritePrompt = $false
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtLogFile.Text = $dlg.FileName
    }
})

$grpLog.Controls.AddRange(@($txtLogFile, $btnBrowse))

# --- Action key group ---
$grpAction = New-Object System.Windows.Forms.GroupBox
$grpAction.Text = "Action key (pressed after each Ctrl+C)"
$grpAction.Location = New-Object System.Drawing.Point(15, 85)
$grpAction.Size = New-Object System.Drawing.Size(435, 95)

$lblAction = New-Object System.Windows.Forms.Label
$lblAction.Text = "Key to press:"
$lblAction.Location = New-Object System.Drawing.Point(15, 28)
$lblAction.Size = New-Object System.Drawing.Size(140, 20)

$txtAction = New-Object System.Windows.Forms.TextBox
$txtAction.Location = New-Object System.Drawing.Point(160, 25)
$txtAction.Size = New-Object System.Drawing.Size(160, 22)
$txtAction.ReadOnly = $true
$txtAction.Text = $existing.ActionKeyDisplay

$btnSetAction = New-Object System.Windows.Forms.Button
$btnSetAction.Text = "Set..."
$btnSetAction.Location = New-Object System.Drawing.Point(330, 23)
$btnSetAction.Size = New-Object System.Drawing.Size(85, 25)
$btnSetAction.Add_Click({
    $script:Capturing = 'Action'
    $script:PreCaptureText = $txtAction.Text
    $txtAction.Text = "Press a key... (Esc to cancel)"
    $txtAction.BackColor = 'LightYellow'
})

$lblActionDelay = New-Object System.Windows.Forms.Label
$lblActionDelay.Text = "Delay after this key, before next Ctrl+C (ms):"
$lblActionDelay.Location = New-Object System.Drawing.Point(15, 63)
$lblActionDelay.Size = New-Object System.Drawing.Size(300, 20)

$numAfterActionDelay = New-Object System.Windows.Forms.NumericUpDown
$numAfterActionDelay.Location = New-Object System.Drawing.Point(330, 60)
$numAfterActionDelay.Size = New-Object System.Drawing.Size(80, 22)
$numAfterActionDelay.Minimum = 0
$numAfterActionDelay.Maximum = 10000
$numAfterActionDelay.Increment = 10
$numAfterActionDelay.Value = [int]$existing.AfterActionKeyDelayMs

$grpAction.Controls.AddRange(@($lblAction, $txtAction, $btnSetAction, $lblActionDelay, $numAfterActionDelay))

# --- Timing group ---
$grpTiming = New-Object System.Windows.Forms.GroupBox
$grpTiming.Text = "Timing (milliseconds)"
$grpTiming.Location = New-Object System.Drawing.Point(15, 190)
$grpTiming.Size = New-Object System.Drawing.Size(435, 85)

$lblCopy = New-Object System.Windows.Forms.Label
$lblCopy.Text = "Delay after Ctrl+C, before reading clipboard:"
$lblCopy.Location = New-Object System.Drawing.Point(15, 28)
$lblCopy.Size = New-Object System.Drawing.Size(300, 20)

$numCopyDelay = New-Object System.Windows.Forms.NumericUpDown
$numCopyDelay.Location = New-Object System.Drawing.Point(330, 25)
$numCopyDelay.Size = New-Object System.Drawing.Size(80, 22)
$numCopyDelay.Minimum = 0
$numCopyDelay.Maximum = 10000
$numCopyDelay.Increment = 10
$numCopyDelay.Value = [int]$existing.CopyDelayMs

$lblTick = New-Object System.Windows.Forms.Label
$lblTick.Text = "Internal poll interval (advanced):"
$lblTick.Location = New-Object System.Drawing.Point(15, 55)
$lblTick.Size = New-Object System.Drawing.Size(300, 20)

$numTimerTick = New-Object System.Windows.Forms.NumericUpDown
$numTimerTick.Location = New-Object System.Drawing.Point(330, 52)
$numTimerTick.Size = New-Object System.Drawing.Size(80, 22)
$numTimerTick.Minimum = 10
$numTimerTick.Maximum = 1000
$numTimerTick.Increment = 10
$numTimerTick.Value = [int]$existing.TimerTickMs

$grpTiming.Controls.AddRange(@($lblCopy, $numCopyDelay, $lblTick, $numTimerTick))

# --- Row filtering group ---
$grpRows = New-Object System.Windows.Forms.GroupBox
$grpRows.Text = "Row filtering (skip rows in each captured chunk before saving)"
$grpRows.Location = New-Object System.Drawing.Point(15, 285)
$grpRows.Size = New-Object System.Drawing.Size(435, 90)

$lblSkipStart = New-Object System.Windows.Forms.Label
$lblSkipStart.Text = "Skip first N rows:"
$lblSkipStart.Location = New-Object System.Drawing.Point(15, 28)
$lblSkipStart.Size = New-Object System.Drawing.Size(300, 20)

$numSkipStart = New-Object System.Windows.Forms.NumericUpDown
$numSkipStart.Location = New-Object System.Drawing.Point(330, 25)
$numSkipStart.Size = New-Object System.Drawing.Size(80, 22)
$numSkipStart.Minimum = 0
$numSkipStart.Maximum = 1000
$numSkipStart.Increment = 1
$numSkipStart.Value = [int]$existing.SkipRowsStart

$lblSkipEnd = New-Object System.Windows.Forms.Label
$lblSkipEnd.Text = "Skip last N rows:"
$lblSkipEnd.Location = New-Object System.Drawing.Point(15, 58)
$lblSkipEnd.Size = New-Object System.Drawing.Size(300, 20)

$numSkipEnd = New-Object System.Windows.Forms.NumericUpDown
$numSkipEnd.Location = New-Object System.Drawing.Point(330, 55)
$numSkipEnd.Size = New-Object System.Drawing.Size(80, 22)
$numSkipEnd.Minimum = 0
$numSkipEnd.Maximum = 1000
$numSkipEnd.Increment = 1
$numSkipEnd.Value = [int]$existing.SkipRowsEnd

$grpRows.Controls.AddRange(@($lblSkipStart, $numSkipStart, $lblSkipEnd, $numSkipEnd))

# --- Duplicate-capture detection group ---
$grpDup = New-Object System.Windows.Forms.GroupBox
$grpDup.Text = "Duplicate-capture detection"
$grpDup.Location = New-Object System.Drawing.Point(15, 385)
$grpDup.Size = New-Object System.Drawing.Size(435, 80)

$chkDupDetect = New-Object System.Windows.Forms.CheckBox
$chkDupDetect.Text = "Pause and ask when back-to-back captures are nearly identical"
$chkDupDetect.Location = New-Object System.Drawing.Point(15, 25)
$chkDupDetect.Size = New-Object System.Drawing.Size(405, 20)
$chkDupDetect.Checked = [bool]$existing.DupDetectEnabled

$lblDupThreshold = New-Object System.Windows.Forms.Label
$lblDupThreshold.Text = "Similarity threshold to trigger the pause (%):"
$lblDupThreshold.Location = New-Object System.Drawing.Point(15, 53)
$lblDupThreshold.Size = New-Object System.Drawing.Size(300, 20)

$numDupThreshold = New-Object System.Windows.Forms.NumericUpDown
$numDupThreshold.Location = New-Object System.Drawing.Point(330, 50)
$numDupThreshold.Size = New-Object System.Drawing.Size(80, 22)
$numDupThreshold.DecimalPlaces = 2
$numDupThreshold.Minimum = 50
$numDupThreshold.Maximum = 100
$numDupThreshold.Increment = 0.1
$rawThreshold = [double]$existing.DupDetectThreshold
if ($rawThreshold -le 1) { $rawThreshold = $rawThreshold * 100 }   # stored as a fraction (0.995) -> show as %
$numDupThreshold.Value = [Math]::Round([Math]::Min([Math]::Max($rawThreshold, 50), 100), 2)

$lblDupThreshold.Enabled = $chkDupDetect.Checked
$numDupThreshold.Enabled = $chkDupDetect.Checked
$chkDupDetect.Add_CheckedChanged({
    $lblDupThreshold.Enabled = $chkDupDetect.Checked
    $numDupThreshold.Enabled = $chkDupDetect.Checked
})

$grpDup.Controls.AddRange(@($chkDupDetect, $lblDupThreshold, $numDupThreshold))

# --- Hotkeys group ---
$grpKeys = New-Object System.Windows.Forms.GroupBox
$grpKeys.Text = "Global hotkeys (need at least one modifier)"
$grpKeys.Location = New-Object System.Drawing.Point(15, 475)
$grpKeys.Size = New-Object System.Drawing.Size(435, 110)

$lblToggle = New-Object System.Windows.Forms.Label
$lblToggle.Text = "Start / stop capture:"
$lblToggle.Location = New-Object System.Drawing.Point(15, 30)
$lblToggle.Size = New-Object System.Drawing.Size(140, 20)

$txtToggle = New-Object System.Windows.Forms.TextBox
$txtToggle.Location = New-Object System.Drawing.Point(160, 27)
$txtToggle.Size = New-Object System.Drawing.Size(160, 22)
$txtToggle.ReadOnly = $true
$txtToggle.Text = $existing.ToggleHotkey.Display

$btnSetToggle = New-Object System.Windows.Forms.Button
$btnSetToggle.Text = "Set..."
$btnSetToggle.Location = New-Object System.Drawing.Point(330, 25)
$btnSetToggle.Size = New-Object System.Drawing.Size(85, 25)
$btnSetToggle.Add_Click({
    $script:Capturing = 'Toggle'
    $script:PreCaptureText = $txtToggle.Text
    $txtToggle.Text = "Press keys... (Esc to cancel)"
    $txtToggle.BackColor = 'LightYellow'
})

$lblExit = New-Object System.Windows.Forms.Label
$lblExit.Text = "Quit CommandRelay:"
$lblExit.Location = New-Object System.Drawing.Point(15, 65)
$lblExit.Size = New-Object System.Drawing.Size(140, 20)

$txtExit = New-Object System.Windows.Forms.TextBox
$txtExit.Location = New-Object System.Drawing.Point(160, 62)
$txtExit.Size = New-Object System.Drawing.Size(160, 22)
$txtExit.ReadOnly = $true
$txtExit.Text = $existing.ExitHotkey.Display

$btnSetExit = New-Object System.Windows.Forms.Button
$btnSetExit.Text = "Set..."
$btnSetExit.Location = New-Object System.Drawing.Point(330, 60)
$btnSetExit.Size = New-Object System.Drawing.Size(85, 25)
$btnSetExit.Add_Click({
    $script:Capturing = 'Exit'
    $script:PreCaptureText = $txtExit.Text
    $txtExit.Text = "Press keys... (Esc to cancel)"
    $txtExit.BackColor = 'LightYellow'
})

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "Hold Ctrl/Alt/Shift (any combination) and press a key."
$lblHint.Location = New-Object System.Drawing.Point(15, 90)
$lblHint.Size = New-Object System.Drawing.Size(400, 15)
$lblHint.Font = New-Object System.Drawing.Font($lblHint.Font.FontFamily, 7.5)
$lblHint.ForeColor = 'Gray'

$grpKeys.Controls.AddRange(@($lblToggle, $txtToggle, $btnSetToggle, $lblExit, $txtExit, $btnSetExit, $lblHint))

# --- Bottom buttons ---
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Save"
$btnSave.Location = New-Object System.Drawing.Point(195, 595)
$btnSave.Size = New-Object System.Drawing.Size(100, 32)

$btnDefaults = New-Object System.Windows.Forms.Button
$btnDefaults.Text = "Reset to Defaults"
$btnDefaults.Location = New-Object System.Drawing.Point(15, 595)
$btnDefaults.Size = New-Object System.Drawing.Size(130, 32)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancel"
$btnCancel.Location = New-Object System.Drawing.Point(320, 595)
$btnCancel.Size = New-Object System.Drawing.Size(100, 32)

$btnDefaults.Add_Click({
    $defaults = Get-DefaultConfig
    $txtLogFile.Text          = $defaults.LogFile
    $txtAction.Text           = $defaults.ActionKeyDisplay
    $numAfterActionDelay.Value = $defaults.AfterActionKeyDelayMs
    $numCopyDelay.Value       = $defaults.CopyDelayMs
    $numTimerTick.Value       = $defaults.TimerTickMs
    $numSkipStart.Value       = $defaults.SkipRowsStart
    $numSkipEnd.Value         = $defaults.SkipRowsEnd
    $chkDupDetect.Checked     = $defaults.DupDetectEnabled
    $numDupThreshold.Value    = [Math]::Round($defaults.DupDetectThreshold * 100, 2)
    $txtToggle.Text           = $defaults.ToggleHotkey.Display
    $txtExit.Text             = $defaults.ExitHotkey.Display
    $script:ToggleMods        = [int]$defaults.ToggleHotkey.Modifiers
    $script:ToggleKey         = [int]$defaults.ToggleHotkey.Key
    $script:ExitMods          = [int]$defaults.ExitHotkey.Modifiers
    $script:ExitKey           = [int]$defaults.ExitHotkey.Key
    $script:ActionToken       = $defaults.ActionKeyToken
})

$btnCancel.Add_Click({ $form.Close() })

$btnSave.Add_Click({
    if ($script:ToggleMods -eq $script:ExitMods -and $script:ToggleKey -eq $script:ExitKey) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Toggle and Exit hotkeys can't be identical. Please set a different combination for one of them.",
            "Duplicate Hotkey", 'OK', 'Warning') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($txtLogFile.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please specify a log file path.", "Missing Log File", 'OK', 'Warning') | Out-Null
        return
    }

    $newConfig = [pscustomobject]@{
        LogFile               = $txtLogFile.Text
        CopyDelayMs           = [int]$numCopyDelay.Value
        AfterActionKeyDelayMs = [int]$numAfterActionDelay.Value
        TimerTickMs           = [int]$numTimerTick.Value
        SkipRowsStart         = [int]$numSkipStart.Value
        SkipRowsEnd           = [int]$numSkipEnd.Value
        ActionKeyDisplay      = $txtAction.Text
        ActionKeyToken        = $script:ActionToken
        DupDetectEnabled      = [bool]$chkDupDetect.Checked
        DupDetectThreshold    = [double]($numDupThreshold.Value / 100)
        ToggleHotkey          = [pscustomobject]@{ Modifiers = $script:ToggleMods; Key = $script:ToggleKey; Display = $txtToggle.Text }
        ExitHotkey            = [pscustomobject]@{ Modifiers = $script:ExitMods;   Key = $script:ExitKey;   Display = $txtExit.Text }
    }

    $newConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8

    [System.Windows.Forms.MessageBox]::Show(
        "Configuration saved to:`n$ConfigPath`n`nRestart CommandRelay for the changes to take effect.",
        "Saved", 'OK', 'Information') | Out-Null
})

$form.Controls.AddRange(@($grpLog, $grpAction, $grpTiming, $grpRows, $grpDup, $grpKeys, $btnSave, $btnDefaults, $btnCancel))

# ------------------------- Key-combo capture ---------------------------
$form.Add_KeyDown({
    param($sender, $e)

    if (-not $script:Capturing) { return }

    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        switch ($script:Capturing) {
            'Toggle' { $txtToggle.Text = $script:PreCaptureText; $txtToggle.BackColor = 'Window' }
            'Exit'   { $txtExit.Text   = $script:PreCaptureText; $txtExit.BackColor   = 'Window' }
            'Action' { $txtAction.Text = $script:PreCaptureText; $txtAction.BackColor = 'Window' }
        }
        $script:Capturing = $null
        $e.Handled = $true
        $e.SuppressKeyPress = $true
        return
    }

    # Ignore pure modifier presses - wait for the actual key
    $modifierKeys = @(
        [System.Windows.Forms.Keys]::ControlKey,
        [System.Windows.Forms.Keys]::Menu,
        [System.Windows.Forms.Keys]::ShiftKey,
        [System.Windows.Forms.Keys]::LWin,
        [System.Windows.Forms.Keys]::RWin
    )
    if ($modifierKeys -contains $e.KeyCode) {
        $e.Handled = $true
        $e.SuppressKeyPress = $true
        return
    }

    # Global hotkeys (Toggle/Exit) require at least one modifier; the
    # Action key does not (a bare F8 is perfectly valid there).
    if ($script:Capturing -ne 'Action' -and -not ($e.Control -or $e.Alt -or $e.Shift)) {
        [System.Windows.Forms.MessageBox]::Show(
            "A hotkey needs at least one modifier (Ctrl, Alt, and/or Shift). Try again.",
            "Modifier required", 'OK', 'Warning') | Out-Null
        $e.Handled = $true
        $e.SuppressKeyPress = $true
        return
    }

    $mods = 0
    $parts = @()
    if ($e.Control) { $mods = $mods -bor 0x0002; $parts += 'Ctrl' }
    if ($e.Alt)     { $mods = $mods -bor 0x0001; $parts += 'Alt' }
    if ($e.Shift)   { $mods = $mods -bor 0x0004; $parts += 'Shift' }

    $vk = [int]$e.KeyCode
    $parts += $e.KeyCode.ToString()
    $display = [string]::Join('+', $parts)

    switch ($script:Capturing) {
        'Toggle' {
            $script:ToggleMods = $mods
            $script:ToggleKey  = $vk
            $txtToggle.Text = $display
            $txtToggle.BackColor = 'Window'
        }
        'Exit' {
            $script:ExitMods = $mods
            $script:ExitKey  = $vk
            $txtExit.Text = $display
            $txtExit.BackColor = 'Window'
        }
        'Action' {
            $script:ActionToken = Convert-KeyToSendKeysToken -Vk $vk -Mods $mods
            $txtAction.Text = $display
            $txtAction.BackColor = 'Window'
        }
    }

    $script:Capturing = $null
    $e.Handled = $true
    $e.SuppressKeyPress = $true
})

[System.Windows.Forms.Application]::Run($form)
