<# : batch part: starts the window below from this same file
@echo off
setlocal
set "ROE_JOIN_GUI=%~f0"
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command ". ([ScriptBlock]::Create([IO.File]::ReadAllText($env:ROE_JOIN_GUI)))"
exit /b 0
#>

# Join a Ring of Elysium 2022 server (roe_server) in a window: the easy way to play.
#
# Double-click it. The window has the servers joined before (and "Add server..." for another
# one), with who plays where on the selected one; the accounts on that server ("Create a new
# account" makes one); the game folder; voice chat; and Play. Under "Advanced": the firewall
# rules (on, off, reset, show), the account backup (export, import) and the log.
#
# It is join.cmd in a window: it needs join.cmd in the same folder and loads its functions, so
# both do the same steps and share their settings, accounts and keys (%APPDATA%\roe-join.json,
# %APPDATA%\roe-join\). join.cmd stays the console version with its commands. This file adds only
# the window: join.cmd's questions become dialogs and its messages the status line. The network,
# the firewall step (with the Windows administrator prompt) and the wait for the game run in a
# background runspace, so the window never freezes. What happened is in
# %APPDATA%\roe-join\gui.log ("Open the log", or "Details").
#
# Windows PowerShell 5.1 and .NET Framework (WPF) only, as on every Windows 10 and 11.

$ErrorActionPreference = 'Stop'

# --- join.cmd --------------------------------------------------------------------------------
# The code both runspaces load: join.cmd without its main part (its settings, constants and
# functions), then the functions of this file, which replace join.cmd's console questions (Ask)
# and output (Write-Host).
function Get-JoinCode([string]$JoinPath, [string]$GuiPath) {
    if (-not (Test-Path -LiteralPath $JoinPath -PathType Leaf)) {
        throw "join.cmd is missing. join-gui.cmd needs join.cmd in the same folder ($(Split-Path -Parent $JoinPath)): put both files there (both are in the server package and on the project page)."
    }
    $parts = @()
    foreach ($file in @($JoinPath, $GuiPath)) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($file), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "$(Split-Path -Leaf $file) is damaged (line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)). Download it again." }
        foreach ($statement in $ast.EndBlock.Statements) {
            $take = if ($file -eq $JoinPath) { $statement -isnot [Management.Automation.Language.TryStatementAst] }
                else { $statement -is [Management.Automation.Language.FunctionDefinitionAst] }
            if ($take) { $parts += $statement.Extent.Text }
        }
    }
    return $parts -join "`n"
}

# --- Between the worker and the window -------------------------------------------------------
# The worker never touches the window: it puts events into $sync.Events (line, ask, stats, game,
# done) and the window takes them out ten times a second.
function Send-GuiEvent([string]$Kind, $Data) { $sync.Events.Enqueue([pscustomobject]@{ Kind = $Kind; Data = $Data }) }
# join.cmd's messages: a line in the status, the details and the log (yellow and red ones as warnings).
function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object, [object]$ForegroundColor, [object]$BackgroundColor, [switch]$NoNewline, [object]$Separator)
    $text = "$(@($Object) -join ' ')".Trim()
    if (-not $text) { return }
    $level = if ("$ForegroundColor" -in @('Red', 'Yellow')) { 'warn' } else { 'info' }
    Send-GuiEvent 'line' ([pscustomobject]@{ Text = $text; Level = $level })
}
# join.cmd's questions: a dialog in the window, which the worker waits for. Cancel stops the step.
function Ask([string]$Question, [string]$Default) {
    $request = [pscustomobject]@{ Question = $Question; Default = $Default; Answer = $null; Cancelled = $false; Done = (New-Object Threading.ManualResetEventSlim $false) }
    Send-GuiEvent 'ask' $request
    $request.Done.Wait()
    if ($request.Cancelled) { throw 'Cancelled.' }
    $answer = "$($request.Answer)".Trim().Trim('"')
    if (-not $answer) { return $Default }
    return $answer
}
# An error in words: the message of what failed, not PowerShell's wrapping around it.
function Get-ErrorMessage($Record) {
    $exception = if ($Record -is [Management.Automation.ErrorRecord]) { $Record.Exception } else { $Record }
    while ($exception -is [Management.Automation.MethodInvocationException] -and $exception.InnerException) { $exception = $exception.InnerException }
    return "$($exception.Message)"
}
# Runs one piece of work in the worker and reports it (done: Ok, Result, Message, Details).
function Invoke-Work([string]$Command, [hashtable]$Arguments) {
    $done = [pscustomobject]@{ Ok = $true; Result = $null; Message = ''; Details = '' }
    try { $done.Result = & $Command @Arguments }
    catch { $done.Ok = $false; $done.Message = Get-ErrorMessage $_; $done.Details = "$($_ | Out-String)$($_.ScriptStackTrace)".Trim() }
    Send-GuiEvent 'done' $done
}

# --- Work in the background --------------------------------------------------------------------
# The selected server: its name, version and who plays where; refreshes the names of its saved
# accounts (renamed in the game).
function Invoke-ServerJob([string]$Server) {
    $ips = Resolve-ServerIps (Get-ServerHost $Server)
    $folder = Get-AccountFolder $Server
    $contact = Connect-Server $ips[0] $folder $ips $false 'join-gui.cmd'
    if ($contact.Info -match '^OK ' -and -not $contact.TooOld) {
        $accounts = Read-Accounts $folder
        if ($accounts.Count -and (Update-AccountNames $ips[0] $folder $accounts)) { Save-Accounts $folder $accounts | Out-Null }
    }
    return [pscustomobject]@{ Server = $Server; Contact = $contact }
}
# Play: the same steps as join.cmd's main part, with the window's answers. Token and AccountName:
# the saved account (New: a new one); UseVoice false: no voice chat this time. Returns once the
# game has exited and the original voice DLL is back.
function Invoke-PlayJob([string]$Client, [string]$Server, [string]$Token, [string]$AccountName, [bool]$New, [bool]$UseVoice) {
    $settings = Read-Settings
    $client = Get-GameFolder $Client
    $hostName = Get-ServerHost $Server
    $firewall = $settings.firewall
    $voice = $settings.voice
    $voiceDll = $settings.voice_dll
    $serverList = Add-ServerUse @(Read-Servers $settings) $Server
    $save = { Save-JoinSettings $client $firewall $voice $voiceDll $serverList }
    $voicePick = $null
    if ($UseVoice) {
        $choice = Get-VoiceChoice $true $voiceDll $client ''
        $voiceDll = $choice.Dll
        $voicePick = $choice.Pick
    }
    & $save
    $serverIps = Resolve-ServerIps $hostName
    $serverIp = $serverIps[0]
    Write-Host "Contacting $serverIp ..."
    $folder = Get-AccountFolder $Server
    $contact = Connect-Server $serverIp $folder $serverIps $true 'join-gui.cmd'
    if ($contact.Info -match '^OK ' -and (Set-ServerName $serverList $Server $contact.Name)) { & $save }
    if ($contact.TooOld) { throw $contact.TooOld }
    if ($contact.Notice) { Write-Host $contact.Notice -ForegroundColor Yellow }
    if ($contact.Regions) { Send-GuiEvent 'stats' ($contact.Regions -replace ' \| ', "`n") }
    $rules = Update-Firewall $client $serverList $Server $serverIps $contact.Listed ([bool]$firewall)
    if ($rules.Check) { Confirm-GuiFirewall $client $rules }
    & $save
    $accounts = Read-Accounts $folder
    $entry = $null
    if (-not $New) {
        $entry = @($accounts | Where-Object { if ($Token) { $_.token -ceq $Token } else { -not $_.token -and $_.name -eq $AccountName } })[0]
        if (-not $entry) { throw "The account $AccountName is no longer saved for this server. Pick another one or create a new account." }
    }
    $login = Connect-Account $serverIp $folder $accounts $entry ''
    & $save
    if ($login.Accounts) {
        $info = $null
        try { $info = Invoke-Account $serverIp $folder 'INFO' } catch { }
        $stats = $null
        try { $stats = Invoke-Account $serverIp $folder 'STATS' } catch { }
        if ($info -match '^OK ') { Send-GuiEvent 'stats' ((Format-ServerNow $info $stats) -replace ' \| ', "`n") }
    }
    $game = Start-Game $client $login.Uid $serverIp $voicePick
    Send-GuiEvent 'game' $true
    try {
        # While the game runs: the server's numbers every 30 s.
        while (-not $game.Process.WaitForExit(30000)) {
            if (-not $login.Accounts) { continue }
            $info = $null
            try { $info = Invoke-Account $serverIp $folder 'INFO' } catch { }
            $stats = $null
            try { $stats = Invoke-Account $serverIp $folder 'STATS' } catch { }
            if ($info -match '^OK ') { Send-GuiEvent 'stats' ("[{0:HH:mm}] {1}" -f (Get-Date), ((Format-ServerNow $info $stats) -replace ' \| ', "`n")) }
        }
    } finally {
        if ($game.VoiceOn) { Restore-Voice $client 15 | Out-Null }
    }
    return $login.Name
}
# What went wrong with the firewall rules and what to do, as lines for the window.
function Get-GuiFirewallText([string[]]$Problems, [string]$Note, $Blocking, [bool]$Admin) {
    $lines = @()
    if ($Note) { $lines += "The firewall rules could not be set. $Note" }
    else { $lines += 'The firewall rules are not as they should be, so the game may not reach the server.' }
    foreach ($problem in @($Problems | Select-Object -First 5)) { $lines += "- $problem" }
    if ($Problems.Count -gt 5) { $lines += "- and $($Problems.Count - 5) more (Advanced > Show the rules)" }
    if (@($Blocking | Where-Object { $_ -and -not $_.Local }).Count) {
        $lines += 'Remove or turn off the rules of the policy or security product where they come from (or ask who manages this PC).'
    }
    if ($Admin) { $lines += 'join-gui.cmd already runs as administrator: the details show the error.' }
    else { $lines += 'Right-click join-gui.cmd > Run as administrator (on a standard Windows account this needs an administrator''s password).' }
    $lines += 'Or turn the firewall rules off under Advanced (then the game can reach the internet).'
    return $lines
}
# After the firewall step: when the rules are not right, says so and asks whether to start anyway.
function Confirm-GuiFirewall([string]$Client, $Rules) {
    $check = Get-FirewallCheck $Client $Rules.Programs $Rules.Check.Wanted $Rules.Check.RulesOn
    $problems = @($check.Problems)
    if (-not $problems.Count) { return }
    foreach ($line in (Get-GuiFirewallText $problems (Get-ElevationNote $Rules.Check.Step) $check.Blocking (Test-Administrator))) { Write-Host $line -ForegroundColor Yellow }
    if ((Ask 'Start the game anyway? (y/n)' 'n') -notmatch '^[yY]') { throw 'Cancelled: the firewall rules are not in place.' }
}
# The server line under the server list: Text and Level (info, warn, error).
function Get-ServerInfoText($Contact) {
    if (-not $Contact.Info) { return [pscustomobject]@{ Text = 'No answer from the account service: the server may be down, or it has no accounts (then it takes a plain name).'; Level = 'warn' } }
    if ($Contact.TooOld) { return [pscustomobject]@{ Text = $Contact.TooOld; Level = 'error' } }
    if ("$($Contact.Info)" -notmatch '^OK ') { return [pscustomobject]@{ Text = "The account service answered: $($Contact.Info)"; Level = 'warn' } }
    $lines = @()
    if ($Contact.Notice) { $lines += $Contact.Notice }
    if ($Contact.Regions) { $lines += $Contact.Regions -replace ' \| ', "`n" } else { $lines += Format-ServerInfo $Contact.Info }
    $level = if ($Contact.Notice) { 'warn' } else { 'info' }
    return [pscustomobject]@{ Text = $lines -join "`n"; Level = $level }
}
# roe-join.json with some values changed (client, firewall, voice, voice_dll, servers).
function Update-Settings([hashtable]$Values) {
    $settings = Read-Settings
    $all = @{ client = "$($settings.client)"; firewall = $settings.firewall; voice = $settings.voice; voice_dll = $settings.voice_dll; servers = @(Read-Servers $settings) }
    foreach ($key in @($Values.Keys)) { $all[$key] = $Values[$key] }
    Save-JoinSettings $all.client $all.firewall $all.voice $all.voice_dll $all.servers
}
# Our voice DLL: the saved one while it exists, else the one next to the scripts.
function Get-GuiVoiceDll {
    $saved = "$((Read-Settings).voice_dll)"
    if ($saved -and (Test-Path -LiteralPath $saved -PathType Leaf)) { return $saved }
    return Get-DefaultVoiceDll
}

# --- The window --------------------------------------------------------------------------------
function Get-GuiXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ring of Elysium 2022: join a server" Width="560" SizeToContent="Height"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="MinWidth" Value="90"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Heading">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,12,0,4"/>
    </Style>
  </Window.Resources>
  <StackPanel Margin="14,4,14,14">
    <TextBlock Style="{StaticResource Heading}" Text="Server"/>
    <DockPanel>
      <Button x:Name="AddServerButton" DockPanel.Dock="Right" Margin="6,0,0,0" Content="Add server..."/>
      <ComboBox x:Name="ServerBox"/>
    </DockPanel>
    <TextBlock x:Name="ServerStats" Margin="0,4,0,0" TextWrapping="Wrap"/>
    <TextBlock Style="{StaticResource Heading}" Text="Account"/>
    <ComboBox x:Name="AccountBox"/>
    <TextBlock Style="{StaticResource Heading}" Text="Game folder"/>
    <DockPanel>
      <Button x:Name="BrowseButton" DockPanel.Dock="Right" Margin="6,0,0,0" Content="Browse..."/>
      <TextBox x:Name="GameBox" IsReadOnly="True" VerticalContentAlignment="Center"/>
    </DockPanel>
    <TextBlock x:Name="GameNote" Margin="0,4,0,0" TextWrapping="Wrap"/>
    <DockPanel Margin="0,14,0,0">
      <Button x:Name="VoiceButton" DockPanel.Dock="Right" Margin="6,0,0,0" Content="Choose folder..."/>
      <CheckBox x:Name="VoiceBox" Content="Voice chat" FontWeight="Bold" VerticalAlignment="Center"/>
    </DockPanel>
    <TextBlock x:Name="VoiceNote" Margin="0,4,0,0" TextWrapping="Wrap"/>
    <Button x:Name="PlayButton" Margin="0,16,0,0" Height="50" FontSize="20" FontWeight="Bold" Content="Play"/>
    <TextBlock x:Name="StatusText" Margin="0,10,0,0" TextWrapping="Wrap" MinHeight="20"/>
    <ToggleButton x:Name="DetailsButton" Margin="0,6,0,0" HorizontalAlignment="Left" Padding="10,2" Content="Details"/>
    <TextBox x:Name="DetailsBox" Margin="0,6,0,0" Height="170" IsReadOnly="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" FontFamily="Consolas" Visibility="Collapsed"/>
    <Expander x:Name="AdvancedBox" Margin="0,12,0,0" Header="Advanced">
      <StackPanel Margin="0,6,0,0">
        <TextBlock x:Name="FirewallText" TextWrapping="Wrap"/>
        <WrapPanel Margin="0,6,0,0">
          <Button x:Name="FirewallOnButton" Margin="0,0,6,6" Content="Firewall rules on"/>
          <Button x:Name="FirewallOffButton" Margin="0,0,6,6" Content="Firewall rules off"/>
          <Button x:Name="FirewallResetButton" Margin="0,0,6,6" Content="Reset all rules"/>
          <Button x:Name="FirewallShowButton" Margin="0,0,6,6" Content="Show the rules"/>
        </WrapPanel>
        <TextBlock Margin="0,6,0,0" TextWrapping="Wrap" Text="Account backup: one file with the keys of every account, to play with them on another PC (join.cmd and join.py read it too). Keep it private."/>
        <WrapPanel Margin="0,6,0,0">
          <Button x:Name="ExportButton" Margin="0,0,6,6" Content="Export accounts..."/>
          <Button x:Name="ImportButton" Margin="0,0,6,6" Content="Import accounts..."/>
          <Button x:Name="LogButton" Margin="0,0,6,6" Content="Open the log"/>
        </WrapPanel>
      </StackPanel>
    </Expander>
  </StackPanel>
</Window>
'@
}
function Get-GuiControlNames {
    return @('ServerBox', 'AddServerButton', 'ServerStats', 'AccountBox', 'GameBox', 'BrowseButton', 'GameNote', 'VoiceBox', 'VoiceButton', 'VoiceNote',
        'PlayButton', 'StatusText', 'DetailsButton', 'DetailsBox', 'AdvancedBox', 'FirewallText', 'FirewallOnButton', 'FirewallOffButton', 'FirewallResetButton',
        'FirewallShowButton', 'ExportButton', 'ImportButton', 'LogButton')
}
function Get-InputXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ring of Elysium 2022" Width="440" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
  <StackPanel Margin="14">
    <TextBlock x:Name="ContextText" Margin="0,0,0,10" TextWrapping="Wrap"/>
    <TextBlock x:Name="PromptText" TextWrapping="Wrap"/>
    <TextBox x:Name="AnswerBox" Margin="0,4,0,0"/>
    <StackPanel Margin="0,14,0,0" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="OkButton" Width="86" Padding="0,3" IsDefault="True" Content="OK"/>
      <Button Width="86" Margin="6,0,0,0" Padding="0,3" IsCancel="True" Content="Cancel"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
}
function Get-GuiLogPath { return Join-Path (Join-Path $env:APPDATA 'roe-join') 'gui.log' }
function Write-GuiLog([string]$Text) {
    try {
        $path = Get-GuiLogPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [IO.File]::AppendAllText($path, ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text) + "`r`n")
    } catch { }
}
function Get-Brush([string]$Level) {
    switch ($Level) {
        'error' { return [Windows.Media.Brushes]::Firebrick }
        'warn' { return New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xA0, 0x50, 0x00)) }
        'muted' { return [Windows.SystemColors]::GrayTextBrush }
    }
    return [Windows.SystemColors]::ControlTextBrush
}
function Set-Text($Control, [string]$Text, [string]$Level = 'info') {
    $Control.Text = $Text
    $Control.Foreground = Get-Brush $Level
}
# A line for the player: the status, the details and the log.
function Add-Line([string]$Text, [string]$Level = 'info') {
    if ($Level -ne 'info') { Write-GuiLog "[$Level] $Text" } else { Write-GuiLog $Text }
    $gui.C.DetailsBox.AppendText("$Text`r`n")
    $gui.C.DetailsBox.ScrollToEnd()
    [void]$gui.Recent.Add($Text)
    while ($gui.Recent.Count -gt 12) { $gui.Recent.RemoveAt(0) }
    Set-Text $gui.C.StatusText $Text $Level
}
function Show-GuiError($Record, [string]$Prefix = '') {
    Write-GuiLog "$($Record | Out-String)$($Record.ScriptStackTrace)".Trim()
    Add-Line ($Prefix + (Get-ErrorMessage $Record)) 'error'
}
function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information', [string]$Default = 'OK') {
    return "$([Windows.MessageBox]::Show($gui.Window, $Text, 'Ring of Elysium 2022', $Buttons, $Icon, $Default))"
}
# A question with a text field; $null when cancelled.
function Show-InputDialog([string]$Prompt, [string]$Context, [string]$Default) {
    $dialog = [Windows.Markup.XamlReader]::Parse((Get-InputXaml))
    if ($gui.Window -and $gui.Window.IsLoaded) { $dialog.Owner = $gui.Window } else { $dialog.WindowStartupLocation = 'CenterScreen' }
    $contextText = $dialog.FindName('ContextText')
    $contextText.Text = $Context
    if (-not $Context) { $contextText.Visibility = 'Collapsed' }
    $dialog.FindName('PromptText').Text = "${Prompt}:"
    $box = $dialog.FindName('AnswerBox')
    $box.Text = $Default
    $dialog.FindName('OkButton').Add_Click({ [Windows.Window]::GetWindow($this).DialogResult = $true })
    $dialog.Add_ContentRendered({ $box = $this.FindName('AnswerBox'); [void]$box.Focus(); $box.SelectAll() })
    if (-not $dialog.ShowDialog()) { return $null }
    return $box.Text
}
# A question of the worker (join.cmd's Ask): yes/no ones as a message box, others with a text field.
function Show-Question($Request) {
    try {
        $context = (@($gui.Recent) | Select-Object -Last 8) -join "`n"
        $gui.Recent.Clear()
        if ($Request.Question -match '^(.*?)\s*\(y/n\)$') {
            $text = (@($context, $Matches[1]) | Where-Object { $_ }) -join "`n`n"
            $default = if ($Request.Default -match '^[yY]') { 'Yes' } else { 'No' }
            $Request.Answer = if ((Show-Message $text 'YesNo' 'Question' $default) -eq 'Yes') { 'y' } else { 'n' }
        } else {
            $answer = Show-InputDialog $Request.Question $context $Request.Default
            if ($null -eq $answer) { $Request.Cancelled = $true } else { $Request.Answer = $answer }
        }
    } catch {
        $Request.Cancelled = $true
        Show-GuiError $_
    } finally {
        $Request.Done.Set()
    }
}
# The events of the worker, on the window's thread.
function Receive-GuiEvents {
    if ($gui.Draining) { return }
    $gui.Draining = $true
    try {
        $item = $null
        while ($sync.Events.TryDequeue([ref]$item)) {
            switch ($item.Kind) {
                'line' { Add-Line $item.Data.Text $item.Data.Level }
                'ask' { Show-Question $item.Data }
                'stats' { Set-Text $gui.C.ServerStats $item.Data }
                'game' {
                    $gui.GameRunning = $true
                    Update-Controls
                    Add-Line 'Game running. This window puts the original voice DLL back when the game exits.'
                }
                'done' { Complete-Work $item.Data }
            }
        }
    } catch {
        Show-GuiError $_
    } finally {
        $gui.Draining = $false
    }
}
# The worker: a runspace with join.cmd and this file's functions, for one piece of work at a time.
function New-Worker([string]$Code) {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('sync', $sync)
    $worker = [powershell]::Create()
    $worker.Runspace = $runspace
    [void]$worker.AddScript($Code).Invoke()
    if ($worker.Streams.Error.Count) { throw "The background part could not load join.cmd: $($worker.Streams.Error[0])" }
    $worker.Commands.Clear()
    return $worker
}
# Queues work for the worker; OnDone gets its done event on the window's thread. A newer request
# for the server line replaces one still waiting.
function Start-Work([string]$Command, [hashtable]$Arguments, [scriptblock]$OnDone) {
    if ($Command -eq 'Invoke-ServerJob') { foreach ($queued in @($gui.Queue | Where-Object { $_.Command -eq $Command })) { $gui.Queue.Remove($queued) } }
    [void]$gui.Queue.Add([pscustomobject]@{ Command = $Command; Arguments = $Arguments; OnDone = $OnDone })
    Start-NextWork
}
function Start-NextWork {
    if (-not $gui.Job -and $gui.Queue.Count) {
        $next = $gui.Queue[0]
        $gui.Queue.RemoveAt(0)
        $gui.Job = $next.Command
        $gui.OnDone = $next.OnDone
        $gui.Worker.Commands.Clear()
        [void]$gui.Worker.AddCommand('Invoke-Work').AddParameter('Command', $next.Command).AddParameter('Arguments', $next.Arguments)
        $gui.Handle = $gui.Worker.BeginInvoke()
    }
    Update-Controls
}
function Complete-Work($Done) {
    try { [void]$gui.Worker.EndInvoke($gui.Handle) } catch { }
    $gui.Worker.Streams.ClearStreams()
    $onDone = $gui.OnDone
    $gui.Job = $null
    $gui.OnDone = $null
    if (-not $Done.Ok -and $Done.Details) { Write-GuiLog $Done.Details }
    try {
        if ($onDone) { & $onDone $Done } elseif (-not $Done.Ok) { Add-Line $Done.Message 'error' }
    } catch { Show-GuiError $_ }
    Start-NextWork
}
function Update-Controls {
    $playing = [bool]$gui.Playing
    foreach ($name in @('ServerBox', 'AddServerButton', 'AccountBox', 'BrowseButton', 'VoiceBox', 'VoiceButton', 'FirewallOnButton', 'FirewallOffButton',
            'FirewallResetButton', 'FirewallShowButton', 'ExportButton', 'ImportButton')) { $gui.C[$name].IsEnabled = -not $playing }
    $gui.C.PlayButton.IsEnabled = -not $playing
    $gui.C.PlayButton.Content = if ($gui.GameRunning) { 'Game running' } elseif ($playing) { 'Joining...' } else { 'Play' }
}
function Get-SelectedServer {
    $index = $gui.C.ServerBox.SelectedIndex
    if ($index -ge 0 -and $index -lt @($gui.Servers).Count) { return $gui.Servers[$index].address }
    return ''
}
# The server list from roe-join.json, Select (an address) selected, else the most recent one.
function Update-ServerList([string]$Select) {
    $gui.Updating = $true
    try {
        $gui.Servers = @(Read-Servers (Read-Settings))
        $box = $gui.C.ServerBox
        $box.Items.Clear()
        $index = 0
        for ($i = 0; $i -lt $gui.Servers.Count; $i++) {
            [void]$box.Items.Add((Get-ServerLabel $gui.Servers[$i]))
            if ($Select -and (Get-ServerFolderName $gui.Servers[$i].address) -eq (Get-ServerFolderName $Select)) { $index = $i }
        }
        if ($gui.Servers.Count) { $box.SelectedIndex = $index }
    } finally {
        $gui.Updating = $false
    }
    Update-AccountList
}
# The accounts of the selected server, the most recent first, and "Create a new account".
function Update-AccountList {
    $gui.Updating = $true
    try {
        $server = Get-SelectedServer
        $gui.Accounts = if ($server) { Read-Accounts (Get-AccountFolder $server) } else { New-Object Collections.ArrayList }
        $box = $gui.C.AccountBox
        $box.Items.Clear()
        foreach ($account in $gui.Accounts) { [void]$box.Items.Add($account.name) }
        [void]$box.Items.Add('Create a new account')
        $box.SelectedIndex = 0
    } finally {
        $gui.Updating = $false
    }
}
function Request-ServerInfo {
    $server = Get-SelectedServer
    if (-not $server) { Set-Text $gui.C.ServerStats 'Add the server the host gave you: Add server... (its IP address or domain).' 'muted'; return }
    Set-Text $gui.C.ServerStats "Contacting $server ..." 'muted'
    Start-Work 'Invoke-ServerJob' @{ Server = $server } { param($done) Show-ServerInfo $done }
}
function Show-ServerInfo($Done) {
    if (-not $Done.Ok) { Set-Text $gui.C.ServerStats $Done.Message 'error'; return }
    $server = $Done.Result.Server
    if ((Get-SelectedServer) -ne $server) { return }  # another one was selected meanwhile; its request follows
    $contact = $Done.Result.Contact
    if ($contact.Name -and -not $gui.Playing) {
        $servers = @(Read-Servers (Read-Settings))
        if (Set-ServerName $servers $server $contact.Name) { Update-Settings @{ servers = $servers }; Update-ServerList $server }
    }
    $line = Get-ServerInfoText $contact
    Set-Text $gui.C.ServerStats $line.Text $line.Level
    if (-not $gui.Playing) {
        $index = $gui.C.AccountBox.SelectedIndex
        Update-AccountList
        if ($index -lt $gui.C.AccountBox.Items.Count) { $gui.C.AccountBox.SelectedIndex = $index }
    }
}
function Update-GameFolder {
    $gui.C.GameBox.Text = $gui.Client
    if (Test-Client $gui.Client) { Set-Text $gui.C.GameNote '' }
    else {
        Set-Text $gui.C.GameNote ('Choose the Ring of Elysium folder with Browse...: usually C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium ' +
            '(DX11), or its XVersion folder (DX12).') 'warn'
    }
}
function Update-Voice {
    $gui.Updating = $true
    try { $gui.C.VoiceBox.IsChecked = (Read-Settings).voice -ne $false } finally { $gui.Updating = $false }
    if (-not $gui.C.VoiceBox.IsChecked) {
        Set-Text $gui.C.VoiceNote 'Voice chat is off.' 'muted'
        $gui.C.VoiceButton.Visibility = 'Collapsed'
        return
    }
    $gui.C.VoiceButton.Visibility = 'Visible'
    $dll = Get-GuiVoiceDll
    $problem = Get-VoiceDllProblem $dll $(if (Test-Client $gui.Client) { $gui.Client } else { '' })
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        Set-Text $gui.C.VoiceNote ("Our $voiceFile is not next to join-gui.cmd or in its voice folder. Choose the folder that has it (the voice folder of the server package), " +
            "or download it from $voiceDownload.") 'warn'
    } elseif ($problem) {
        Set-Text $gui.C.VoiceNote "Voice chat: $problem. Choose the folder with ours." 'warn'
    } else {
        Set-Text $gui.C.VoiceNote "Our $voiceFile ($dll) goes into the game folder while the game runs; the original is put back afterwards." 'muted'
    }
}
function Update-FirewallText {
    $firewall = (Read-Settings).firewall
    $state = if ($null -eq $firewall) { 'not chosen yet (asked at the first Play)' } elseif ($firewall) { 'on' } else { 'off' }
    $gui.C.FirewallText.Text = "Firewall rules: $state. When on, the game can reach only the servers you join, nothing else on the internet (setting them needs administrator approval when the allowed addresses change)."
}
# A folder picker; '' when cancelled.
function Select-Folder([string]$Description, [string]$Start) {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $false
    if ($Start -and (Test-Path -LiteralPath $Start -PathType Container)) { $dialog.SelectedPath = $Start }
    try { if ("$($dialog.ShowDialog())" -ne 'OK') { return '' }; return $dialog.SelectedPath } finally { $dialog.Dispose() }
}
function Select-GameFolder {
    $path = Select-Folder 'The Ring of Elysium game folder: the one with Europa_Client.exe (XVersion inside it for DX12).' $gui.Client
    if (-not $path) { return }
    if (-not (Test-Client $path)) { Add-Line "No Europa_Client.exe in $path. Choose the Ring of Elysium folder (or its XVersion folder)." 'error'; return }
    Add-Line "Checking the game in $path ..."
    Start-Work 'Get-GameFolder' @{ Folder = $path } {
        param($done)
        if (-not $done.Ok) { Add-Line $done.Message 'error'; return }
        $gui.Client = $done.Result
        Update-Settings @{ client = $gui.Client }
        Update-GameFolder
        Update-Voice
        Add-Line "Game folder: $($gui.Client) (the tested version)."
    }
}
function Select-VoiceFolder {
    $start = Split-Path -Parent (Get-GuiVoiceDll)
    $path = Select-Folder "The folder with our $voiceFile (the voice folder of the server package)." $start
    if (-not $path) { return }
    $dll = Resolve-VoiceDll $path
    $problem = Get-VoiceDllProblem $dll $(if (Test-Client $gui.Client) { $gui.Client } else { '' })
    if ($problem) { Add-Line "Voice chat: $problem." 'error'; return }
    Update-Settings @{ voice_dll = [IO.Path]::GetFullPath($dll); voice = $true }
    Update-Voice
    Add-Line "Voice chat: our $voiceFile is $dll."
}
function Add-GuiServer {
    $address = Show-InputDialog 'Server address (IP or domain)' 'The host of the server gives you its address, for example 203.0.113.5 or play.example.org.' ''
    if ($null -eq $address) { return }
    $address = $address.Trim()
    if (-not $address) { return }
    if (-not (Test-BackupAddress $address)) { Add-Line "That is no IP address or domain: $address" 'error'; return }
    try { [void](Get-ServerHost $address) } catch { Show-GuiError $_; return }
    Update-Settings @{ servers = @(Add-ServerUse @(Read-Servers (Read-Settings)) $address) }
    Update-ServerList $address
    Request-ServerInfo
}
function Start-Play {
    $server = Get-SelectedServer
    if (-not $server) { Add-Line 'Add the server first: Add server...' 'error'; return }
    if (-not (Test-Client $gui.Client)) { Add-Line 'Choose the game folder first: Browse...' 'error'; return }
    if ($null -eq (Read-Settings).firewall) {
        $answer = Show-Message ('join-gui.cmd can add Windows Firewall rules so the game reaches only the servers you join (it also tries the ' +
            "publisher's old servers). That needs administrator approval (a Windows prompt) when the allowed addresses change.`n`n" +
            'Add the firewall rules? (Change it later under Advanced.)') 'YesNo' 'Question' 'Yes'
        Update-Settings @{ firewall = $answer -eq 'Yes' }
        Update-FirewallText
    }
    $voiceOn = [bool]$gui.C.VoiceBox.IsChecked
    $useVoice = $voiceOn
    if ($voiceOn) {
        $problem = Get-VoiceDllProblem (Get-GuiVoiceDll) $gui.Client
        if ($problem) {
            if ((Show-Message "Voice chat: $problem.`n`nPlay without voice chat this time?" 'YesNo' 'Question' 'Yes') -ne 'Yes') { return }
            $useVoice = $false
        }
    }
    Update-Settings @{ voice = $voiceOn }
    $index = $gui.C.AccountBox.SelectedIndex
    $entry = if ($index -ge 0 -and $index -lt $gui.Accounts.Count) { $gui.Accounts[$index] } else { $null }
    $gui.Playing = $true
    Add-Line "Joining $server ..."
    Start-Work 'Invoke-PlayJob' @{ Client = $gui.Client; Server = $server; Token = "$($entry.token)"; AccountName = "$($entry.name)"; New = ($null -eq $entry); UseVoice = $useVoice } {
        param($done)
        $gui.Playing = $false
        $gui.GameRunning = $false
        if ($done.Ok) { Add-Line 'The game has exited.' } else { Add-Line "Could not join: $($done.Message)" 'error' }
        Update-ServerList (Get-SelectedServer)
        Update-FirewallText
        Update-Voice
    }
}
function Set-GuiFirewall([string]$Action) {
    $client = if (Test-Client $gui.Client) { $gui.Client } else { '' }
    switch ($Action) {
        'on' {
            Update-Settings @{ firewall = $true }
            Add-Line 'Firewall rules on: the next Play sets them.'
        }
        'off' {
            Update-Settings @{ firewall = $false }
            Start-Work 'Remove-FolderRules' @{ Client = $client } {
                param($done)
                if ($done.Ok) { Add-Line 'Firewall rules off: join-gui.cmd no longer sets them (the game can reach the internet).' } else { Add-Line $done.Message 'error' }
            }
        }
        'reset' {
            if ((Show-Message "Remove the firewall rules of every game folder (join.cmd's, join-gui.cmd's and the server launcher's)? The next Play allows only its own server." 'YesNo' 'Question' 'No') -ne 'Yes') { return }
            Start-Work 'Reset-AllRules' @{} $null
        }
        'show' {
            $gui.C.DetailsButton.IsChecked = $true
            Start-Work 'Show-Firewall' @{ Client = $client; Firewall = (Read-Settings).firewall } $null
        }
    }
    Update-FirewallText
}
function Export-GuiAccounts {
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = 'roe-join-accounts.json'
    $dialog.Filter = 'Account backup (*.json)|*.json|All files (*.*)|*.*'
    if ($dialog.ShowDialog($gui.Window) -ne $true) { return }
    $done = Export-Accounts $joinRoot (Read-Settings) $dialog.FileName
    Add-Line "Saved $($done.Accounts) accounts of $($done.Servers) servers in $($dialog.FileName). On the other PC: Import accounts... (or join.cmd import <file>)."
    Add-Line $backupWarning 'warn'
}
function Import-GuiAccounts {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Account backup (*.json)|*.json|All files (*.*)|*.*'
    if ($dialog.ShowDialog($gui.Window) -ne $true) { return }
    Add-Line $backupWarning 'warn'
    Start-Work 'Import-Accounts' @{ Root = $joinRoot; Settings = (Read-Settings); File = $dialog.FileName } {
        param($done)
        if (-not $done.Ok) { Add-Line "Could not import: $($done.Message)" 'error'; return }
        Update-Settings @{ servers = @($done.Result.Servers) }
        $line = "Imported: $($done.Result.Added) new accounts, $($done.Result.Updated) updated (used more recently in the backup)."
        if (@($done.Result.Skipped).Count) { $line += " Skipped (another certificate): $($done.Result.Skipped -join ', ')." }
        Add-Line "$line You may delete the backup file now."
        Update-ServerList (Get-SelectedServer)
        Request-ServerInfo
    }
}
function Open-GuiLog {
    $path = Get-GuiLogPath
    if (-not (Test-Path -LiteralPath $path)) { Write-GuiLog 'Log opened.' }
    Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$path`""
}
# Control.Event runs Action; an error there becomes a line, never a crash.
function Add-Handler($Control, [string]$Event, [scriptblock]$Action) {
    $Control."Add_$Event"({ try { & $Action } catch { Show-GuiError $_ } }.GetNewClosure())
}
function Start-Gui([string]$Code) {
    $log = Get-GuiLogPath
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) { Move-Item -LiteralPath $log -Destination ($log -replace '\.log$', '.old.log') -Force }
    Write-GuiLog "join-gui.cmd $joinVersion starts ($env:ROE_JOIN_GUI)."
    $window = [Windows.Markup.XamlReader]::Parse((Get-GuiXaml))
    $gui.Window = $window
    $gui.C = @{}
    foreach ($name in (Get-GuiControlNames)) { $gui.C[$name] = $window.FindName($name) }
    $gui.Recent = New-Object Collections.ArrayList
    $gui.Queue = New-Object Collections.ArrayList
    $gui.Job = $null; $gui.Playing = $false; $gui.GameRunning = $false; $gui.Updating = $false; $gui.Draining = $false
    $gui.Worker = New-Worker $Code

    $settings = Read-Settings
    $gui.Client = "$($settings.client)"
    if (-not (Test-Client $gui.Client)) {
        $guess = 'C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium'
        $gui.Client = if (Test-Client $guess) { $guess } else { '' }
    }
    Update-GameFolder
    Update-ServerList ''
    Update-Voice
    Update-FirewallText
    Update-Controls
    Set-Text $gui.C.StatusText 'Choose the server and the account, then Play.' 'muted'

    Add-Handler $gui.C.ServerBox 'SelectionChanged' { if (-not $gui.Updating) { Update-AccountList; Request-ServerInfo } }
    Add-Handler $gui.C.AddServerButton 'Click' { Add-GuiServer }
    Add-Handler $gui.C.BrowseButton 'Click' { Select-GameFolder }
    Add-Handler $gui.C.VoiceBox 'Click' { Update-Settings @{ voice = [bool]$gui.C.VoiceBox.IsChecked }; Update-Voice }
    Add-Handler $gui.C.VoiceButton 'Click' { Select-VoiceFolder }
    Add-Handler $gui.C.PlayButton 'Click' { Start-Play }
    Add-Handler $gui.C.DetailsButton 'Checked' { $gui.C.DetailsBox.Visibility = 'Visible' }
    Add-Handler $gui.C.DetailsButton 'Unchecked' { $gui.C.DetailsBox.Visibility = 'Collapsed' }
    Add-Handler $gui.C.FirewallOnButton 'Click' { Set-GuiFirewall 'on' }
    Add-Handler $gui.C.FirewallOffButton 'Click' { Set-GuiFirewall 'off' }
    Add-Handler $gui.C.FirewallResetButton 'Click' { Set-GuiFirewall 'reset' }
    Add-Handler $gui.C.FirewallShowButton 'Click' { Set-GuiFirewall 'show' }
    Add-Handler $gui.C.ExportButton 'Click' { Export-GuiAccounts }
    Add-Handler $gui.C.ImportButton 'Click' { Import-GuiAccounts }
    Add-Handler $gui.C.LogButton 'Click' { Open-GuiLog }
    $window.Add_Closing({
        param($sender, $e)
        if (-not $gui.Playing) { return }
        $answer = Show-Message ("join-gui.cmd is still joining or waits for the game to exit, to put the game's original $voiceFile back. " +
            'Close it anyway? Then the next start of join-gui.cmd or join.cmd puts it back.') 'YesNo' 'Warning' 'No'
        if ($answer -ne 'Yes') { $e.Cancel = $true }
    })
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({ Receive-GuiEvents })
    $timer.Start()
    # Our voice DLL left by a crash or a closed window: the original back first.
    Start-Work 'Restore-AllVoice' @{} $null
    Request-ServerInfo
    [void]$window.ShowDialog()
    $timer.Stop()
    Write-GuiLog 'join-gui.cmd closed.'
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    $guiPath = "$env:ROE_JOIN_GUI"
    if (-not $guiPath) { throw 'Start join-gui.cmd by double-clicking it.' }
    $joinPath = Join-Path (Split-Path -Parent $guiPath) 'join.cmd'
    $env:ROE_JOIN_SELF = $joinPath
    $sync = [hashtable]::Synchronized(@{ Events = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]' })
    $gui = @{}
    $joinCode = Get-JoinCode $joinPath $guiPath
    . ([ScriptBlock]::Create($joinCode))
    Start-Gui $joinCode
} catch {
    $message = Get-ErrorMessage $_
    Write-GuiLog "join-gui.cmd could not start: $message`r`n$($_ | Out-String)$($_.ScriptStackTrace)"
    try { [void][Windows.MessageBox]::Show("join-gui.cmd could not start: $message`n`nDetails: $(Get-GuiLogPath)", 'Ring of Elysium 2022', 'OK', 'Error') } catch { }
}
[Environment]::Exit(0)
