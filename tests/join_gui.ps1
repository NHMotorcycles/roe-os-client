# join-gui.cmd without a window on screen: it loads join.cmd (Source, copied to a .ps1) the way
# it does at its start, its windows parse, the worker runspace takes work and asks questions
# through the event queue, and its server and play steps work against a fake account service.
# Prints OK or FAIL lines.
param([string]$Source, [string]$Base)
$ErrorActionPreference = 'Stop'
$guiFile = Join-Path $Base 'join-gui.cmd'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiFile, [ref]$tokens, [ref]$errors)
if ($errors.Count) { foreach ($e in $errors) { "FAIL parse: $e" }; exit 2 }
'OK parse'
foreach ($f in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([ScriptBlock]::Create($f.Extent.Text))
}
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "OK $Name" } else { "FAIL $Name" } }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$sync = [hashtable]::Synchronized(@{ Events = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]' })
$gui = @{}
function Next-Event([int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $item = $null
    while ((Get-Date) -lt $deadline) { if ($sync.Events.TryDequeue([ref]$item)) { return $item }; Start-Sleep -Milliseconds 20 }
    return $null
}

# join.cmd without its main part, then join-gui.cmd's functions over it.
$missing = ''
try { Get-JoinCode (Join-Path $Base 'nothing.cmd') $guiFile | Out-Null } catch { $missing = $_.Exception.Message }
Check 'join.cmd missing' ($missing -like 'join.cmd is missing. join-gui.cmd needs join.cmd in the same folder*')
$code = Get-JoinCode $Source $guiFile
Check 'join code' ($code -match 'function Invoke-Login' -and $code -match '\$expectedSha = ' -and $code -notmatch 'Ring of Elysium 2022: join a server''' -and
    $code -notmatch 'Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms' -and
    $code.LastIndexOf('function Ask(') -gt $code.IndexOf('function Ask('))
$env:ROE_JOIN_SELF = Join-Path $Base 'join.cmd'
. ([ScriptBlock]::Create($code))
Check 'loaded' ($joinVersion -and (Get-Command Connect-Server -CommandType Function) -and (Get-Command Write-Host).CommandType -eq 'Function')

# join.cmd's messages become events.
Write-Host 'Voice chat: on.'
Write-Host 'It failed.' -ForegroundColor Yellow
Write-Host ''
$first = Next-Event 1; $second = Next-Event 1
Check 'lines' ($first.Kind -eq 'line' -and $first.Data.Text -eq 'Voice chat: on.' -and $first.Data.Level -eq 'info' -and $second.Data.Level -eq 'warn' -and $null -eq (Next-Event 0))

# The windows parse and have every control.
$window = [Windows.Markup.XamlReader]::Parse((Get-GuiXaml))
$gui.C = @{}
foreach ($name in (Get-GuiControlNames)) { $gui.C[$name] = $window.FindName($name) }
Check 'main window' (@($gui.C.Values | Where-Object { $null -eq $_ }).Count -eq 0 -and $gui.C.Count -eq (Get-GuiControlNames).Count)
$dialog = [Windows.Markup.XamlReader]::Parse((Get-InputXaml))
Check 'input dialog' ($dialog.FindName('AnswerBox') -and $dialog.FindName('OkButton') -and $dialog.FindName('PromptText'))
# While the game runs the admin page still opens (its own worker); not twice at once.
$gui.Playing = $true; $gui.GameRunning = $true; $gui.SideJob = $null
Update-Controls
$ok = $gui.C.AdminButton.IsEnabled -and -not $gui.C.PlayButton.IsEnabled -and -not $gui.C.AccountBox.IsEnabled -and "$($gui.C.PlayButton.Content)" -eq 'Game running'
$gui.SideJob = 'Invoke-AdminJob'
Update-Controls
Check 'admin while playing' ($ok -and -not $gui.C.AdminButton.IsEnabled)
$gui.Playing = $false; $gui.GameRunning = $false; $gui.SideJob = $null
# The admin page's part: hidden until the selected account is a GM on the selected server.
Check 'admin part hidden' ("$($gui.C.AdminPanel.Visibility)" -eq 'Collapsed')
$ga = 'a' * 64; $gb = 'b' * 64
$gui.Servers = @([pscustomobject]@{ address = 'a.example' })
[void]$gui.C.ServerBox.Items.Add('a.example')
$gui.C.ServerBox.SelectedIndex = 0
$gui.Accounts = @([pscustomobject]@{ name = 'Anna'; token = $ga }, [pscustomobject]@{ name = 'Ben'; token = $gb })
foreach ($n in @('Anna', 'Ben', 'Create a new account')) { [void]$gui.C.AccountBox.Items.Add($n) }
$gui.C.AccountBox.SelectedIndex = 0
$gui.Roles = @{ $ga = 'gm'; $gb = 'player' }
$gui.RolesServer = 'a.example'
Update-AdminPanel
$shown = "$($gui.C.AdminPanel.Visibility)"
$gui.C.AccountBox.SelectedIndex = 1
Update-AdminPanel
$player = "$($gui.C.AdminPanel.Visibility)"
$gui.C.AccountBox.SelectedIndex = 2
Update-AdminPanel
$new = "$($gui.C.AdminPanel.Visibility)"
$gui.C.AccountBox.SelectedIndex = 0
$gui.RolesServer = 'b.example'
Update-AdminPanel
$other = "$($gui.C.AdminPanel.Visibility)"
Check 'admin part: GM only' ($shown -eq 'Visible' -and $player -eq 'Collapsed' -and $new -eq 'Collapsed' -and $other -eq 'Collapsed')
Check 'admin shown' ((Test-ShowAdmin @{ $ga = 'gm' } ([pscustomobject]@{ token = $ga })) -and -not (Test-ShowAdmin @{ $ga = 'player' } ([pscustomobject]@{ token = $ga })) -and
    -not (Test-ShowAdmin $null ([pscustomobject]@{ token = $ga })) -and -not (Test-ShowAdmin @{ $ga = 'gm' } $null) -and -not (Test-ShowAdmin @{ '' = 'gm' } ([pscustomobject]@{ token = '' })))
$gui.Servers = @(); $gui.Accounts = @(); $gui.Roles = $null; $gui.RolesServer = ''

# The game folder: the Ring of Elysium folder and the DirectX 12 box (its XVersion folder).
$both = Join-Path $Base 'roe-both'; $dx11 = Join-Path $Base 'roe-dx11'; $dx12 = Join-Path $Base 'roe-dx12'
foreach ($f in @((Join-Path $both 'Europa_Client.exe'), (Join-Path $both 'XVersion\Europa_Client.exe'), (Join-Path $dx11 'Europa_Client.exe'), (Join-Path $dx12 'XVersion\Europa_Client.exe'))) {
    New-Item -ItemType File -Force -Path $f | Out-Null
}
$s1 = Split-GameFolder (Join-Path $both 'XVersion'); $s2 = Split-GameFolder "$both\"; $s3 = Split-GameFolder ''
Check 'game folder: split' ($s1.Base -eq $both -and $s1.Dx12 -and $s2.Base -eq $both -and -not $s2.Dx12 -and $s3.Base -eq '' -and -not $s3.Dx12)
$c1 = Get-GameFolderChoice $both $true; $c2 = Get-GameFolderChoice $both $false
Check 'game folder: both versions' ($c1.Folder -eq (Join-Path $both 'XVersion') -and -not $c1.Problem -and $c2.Folder -eq $both -and -not $c2.Problem)
$c3 = Get-GameFolderChoice $dx11 $true; $c4 = Get-GameFolderChoice $dx12 $false; $c5 = Get-GameFolderChoice (Join-Path $Base 'nothing') $false
Check 'game folder: what is missing' (-not $c3.Folder -and $c3.Problem -like "No DirectX 12 version found in $dx11*uncheck DirectX 12." -and
    -not $c4.Folder -and $c4.Problem -like "No DirectX 11 version found in $dx12*tick DirectX 12*" -and -not $c5.Folder -and $c5.Problem -like 'No Europa_Client.exe in *')
$gui.GameBase = $dx12; $gui.Dx12 = $true
Update-GameFolder
$ok = $gui.Client -eq (Join-Path $dx12 'XVersion') -and $gui.C.Dx12Box.IsChecked -and $gui.C.GameBox.Text -eq $dx12
$gui.Dx12 = $false
Update-GameFolder
Check 'game folder: the window' ($ok -and $gui.Client -eq '' -and -not $gui.C.Dx12Box.IsChecked -and $gui.C.GameNote.Text -like 'No DirectX 11 version found*')
$gui.GameBase = ''; $gui.Dx12 = $false; $gui.Client = ''
$gui.C.ServerBox.Items.Clear(); $gui.C.AccountBox.Items.Clear()

# The worker: work in the background, its questions answered here.
$worker = New-Worker $code
[void]$worker.AddCommand('Invoke-Work').AddParameter('Command', 'Get-ServerHost').AddParameter('Arguments', @{ Server = 'play.example:8001' })
$handle = $worker.BeginInvoke()
$done = Next-Event
[void]$worker.EndInvoke($handle)
Check 'worker work' ($done.Kind -eq 'done' -and $done.Data.Ok -and $done.Data.Result -eq 'play.example')
$worker.Commands.Clear()
[void]$worker.AddCommand('Invoke-Work').AddParameter('Command', 'Get-ServerHost').AddParameter('Arguments', @{ Server = 'play.example:8001' }).AddParameter('Event', 'side-done')
$handle = $worker.BeginInvoke()
$done = Next-Event
[void]$worker.EndInvoke($handle)
Check 'side worker event' ($done.Kind -eq 'side-done' -and $done.Data.Ok -and $done.Data.Result -eq 'play.example')
$worker.Commands.Clear()
[void]$worker.AddCommand('Invoke-Work').AddParameter('Command', 'Get-ServerHost').AddParameter('Arguments', @{ Server = 'play.example:9' })
$handle = $worker.BeginInvoke()
$done = Next-Event
[void]$worker.EndInvoke($handle)
Check 'worker error' ($done.Kind -eq 'done' -and -not $done.Data.Ok -and $done.Data.Message -like 'The game only connects to port 8001*' -and $done.Data.Details)
$worker.Commands.Clear()
[void]$worker.AddCommand('Invoke-Work').AddParameter('Command', 'Ask-Name').AddParameter('Arguments', @{ Default = '' })
$handle = $worker.BeginInvoke()
$ask = Next-Event
$ask.Data.Answer = 'Zoe'
$ask.Data.Done.Set()
$done = Next-Event
[void]$worker.EndInvoke($handle)
Check 'worker asks' ($ask.Kind -eq 'ask' -and $ask.Data.Question -like 'Your name*' -and $done.Data.Ok -and $done.Data.Result -eq 'Zoe')
$worker.Commands.Clear()
[void]$worker.AddCommand('Invoke-Work').AddParameter('Command', 'Ask-Name').AddParameter('Arguments', @{ Default = '' })
$handle = $worker.BeginInvoke()
$ask = Next-Event
$ask.Data.Cancelled = $true
$ask.Data.Done.Set()
$done = Next-Event
[void]$worker.EndInvoke($handle)
Check 'cancel stops' (-not $done.Data.Ok -and $done.Data.Message -eq 'Cancelled.')
$worker.Runspace.Dispose()
$worker.Dispose()

# The firewall text and the server line.
$text = (Get-GuiFirewallText @('no join.cmd rule for 2 of 2 game programs') (Get-ElevationNote ([pscustomobject]@{ Ok = $false; Reason = 'declined'; Detail = '' })) @() $false) -join "`n"
Check 'firewall text' ($text -like 'The firewall rules could not be set. The administrator prompt was declined*' -and $text -match 'Right-click join-gui\.cmd > Run as administrator' -and
    $text -match 'off under Advanced' -and $text -match '- no join\.cmd rule')
$text = (Get-GuiFirewallText @(1..7 | ForEach-Object { "problem $_" }) '' @([pscustomobject]@{ Local = $false }) $true) -join "`n"
Check 'firewall text: policy, admin' ($text -like 'The firewall rules are not as they should be*' -and $text -match 'and 2 more' -and $text -match 'policy or security product' -and $text -notmatch 'Right-click')
$line = Get-ServerInfoText ([pscustomobject]@{ Info = 'OK players=2'; TooOld = ''; Notice = $null; Regions = 'EU (normal): 2 online, 0 searching, 0 matches | AS (duel): 0 online, 0 searching, 0 matches' })
Check 'server line' ($line.Level -eq 'info' -and $line.Text -eq "EU (normal): 2 online, 0 searching, 0 matches`nAS (duel): 0 online, 0 searching, 0 matches")
$line = Get-ServerInfoText ([pscustomobject]@{ Info = 'OK players=2 matches=1 waiting=0'; TooOld = ''; Notice = 'A newer join-gui.cmd'; Regions = '' })
Check 'server line: older server' ($line.Level -eq 'warn' -and $line.Text -like "A newer join-gui.cmd`nOn the server now: 2 players online, 1 match running*")
Check 'server line: no service, too old' ((Get-ServerInfoText ([pscustomobject]@{ Info = $null })).Text -like 'No answer from the account service*' -and
    (Get-ServerInfoText ([pscustomobject]@{ Info = 'OK'; TooOld = 'This join-gui.cmd is version 0.9' })).Level -eq 'error')

# Settings: changed values, the others kept.
$settingsPath = Join-Path $Base 'roe-join.json'
$joinRoot = Join-Path $Base 'roe-join'
Save-JoinSettings 'C:\Game' $true $false 'C:\voice\GCloudVoice.dll' @([pscustomobject]@{ address = 'a.example'; last_used = 5; name = ''; addresses = [string[]]@(); ips = [string[]]@() })
Update-Settings @{ voice = $true }
$read = Read-Settings
Check 'settings changed' ($read.voice -eq $true -and $read.firewall -eq $true -and $read.client -eq 'C:\Game' -and $read.voice_dll -eq 'C:\voice\GCloudVoice.dll' -and $read.servers[0].address -eq 'a.example')

# The server step against a fake account service: name, regions, renamed accounts.
$global:Replies = @{}
$global:Sent = New-Object System.Collections.ArrayList
function Invoke-Account([string]$Ip, [string]$Folder, [string]$Line) { [void]$global:Sent.Add($Line); return $global:Replies[$Line] }
$t1 = 'a' * 64; $t2 = 'b' * 64
$folder = Get-AccountFolder '127.0.0.5'
Save-Accounts $folder ([System.Collections.ArrayList]@([pscustomobject]@{ name = 'newaccount1234'; token = $t1; last_used = 9 })) | Out-Null
$global:Replies = @{ 'INFO' = 'OK players=1 name=Test%20Server'; 'VERSION' = 'OK min=0 current=0'; 'STATS' = 'OK 7,normal,1,0,0,EU'; "NAME $t1" = 'OK Anna' }
$r = Invoke-ServerJob '127.0.0.5'
Check 'server step' ($r.Contact.Name -eq 'Test Server' -and $r.Contact.Regions -like 'EU (normal)*' -and $global:Sent -notcontains 'ADDRESSES' -and (Read-Accounts $folder)[0].name -eq 'Anna')
Check 'server step: no role' ($global:Sent -contains "ROLE $t1" -and $r.Roles.Count -eq 0)
$global:Replies["ROLE $t1"] = 'OK gm'
$r = Invoke-ServerJob '127.0.0.5'
Check 'server step: roles' ($r.Roles[$t1] -eq 'gm' -and $r.Roles.Count -eq 1)
# Open the admin page: the link of the server's address in the browser; refused for a player.
function Start-Process { param([Parameter(Position = 0)]$FilePath) $global:Opened = "$FilePath" }
$global:Replies["WEB $t1"] = "OK $('c' * 64) https%3A%2F%2Fadmin.example.org"
$url = Invoke-AdminJob '127.0.0.5' $t1
Check 'admin job' ($url -eq "https://admin.example.org/login?ticket=$('c' * 64)" -and $global:Opened -eq $url)
$global:Replies["ROLE $t1"] = 'OK player'
$stop = ''
try { Invoke-AdminJob '127.0.0.5' $t1 | Out-Null } catch { $stop = $_.Exception.Message }
Check 'admin job: no GM' ($stop -eq 'This account has no GM rights on this server.')

# The play step with the game and the firewall replaced: the saved account by its key, the server's
# name saved, the game event, the voice DLL left alone without voice.
function Get-GameFolder([string]$Folder) { return $Folder }
function Update-Firewall([string]$Client, $ServerList, [string]$Server, [string[]]$ServerIps, $Listed, [bool]$Firewall) {
    $global:Firewall = @($Server, (@($Listed) -join ','), $Firewall)
    Set-ServerAddresses $ServerList $Server $Listed ([string[]]@())
    return [pscustomobject]@{ Programs = @(); Check = $null }
}
function Start-Game([string]$Client, [string]$Uid, [string]$Ip, $VoicePick) {
    $global:Started = @($Client, $Uid, $Ip, $VoicePick)
    $process = [pscustomobject]@{}
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
    return [pscustomobject]@{ Process = $process; VoiceOn = $false }
}
Save-Accounts $folder ([System.Collections.ArrayList]@([pscustomobject]@{ name = 'Anna'; token = $t1; last_used = 9 }, [pscustomobject]@{ name = 'Ben'; token = $t2; last_used = 8 })) | Out-Null
$global:Replies = @{ 'INFO' = 'OK players=1 name=Test%20Server'; 'VERSION' = 'OK min=0 current=0'; 'ADDRESSES' = 'OK 198.51.100.7'; 'STATS' = 'OK'; "LOGIN2 $t2" = 'OK 77 Ben' }
Save-JoinSettings 'C:\Game' $false $true $null @()
$name = Invoke-PlayJob (Join-Path $Base 'game') '127.0.0.5' $t2 'Ben' $false $false
$events = @(); $item = $null
while ($sync.Events.TryDequeue([ref]$item)) { $events += $item }
$read = Read-Settings
Check 'play step' ($name -eq 'Ben' -and $global:Started[1] -eq '77' -and $global:Started[2] -eq '127.0.0.5' -and $null -eq $global:Started[3] -and
    $global:Firewall[1] -eq '198.51.100.7' -and $global:Firewall[2] -eq $false -and @($events | Where-Object { $_.Kind -eq 'game' }).Count -eq 1)
Check 'play saves' ($read.servers[0].address -eq '127.0.0.5' -and $read.servers[0].name -eq 'Test Server' -and $read.voice -eq $true -and
    (@($read.servers[0].addresses) -join ',') -eq '198.51.100.7' -and (Read-Accounts $folder)[0].name -eq 'Ben')
$stop = ''
try { Invoke-PlayJob (Join-Path $Base 'game') '127.0.0.5' ('c' * 64) 'Gone' $false $false | Out-Null } catch { $stop = $_.Exception.Message }
Check 'play: account gone' ($stop -like 'The account Gone is no longer saved for this server*')
$global:Replies['VERSION'] = 'OK min=9 current=9'
$stop = ''
try { Invoke-PlayJob (Join-Path $Base 'game') '127.0.0.5' $t2 'Ben' $false $false | Out-Null } catch { $stop = $_.Exception.Message }
Check 'play: too old' ($stop -like 'This join-gui.cmd is version*Download the new join-gui.cmd*')
