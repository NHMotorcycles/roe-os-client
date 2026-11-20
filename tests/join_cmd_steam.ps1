# join.cmd's start through Steam in the folder Base that test_join.py made (localconfig.vdf samples
# with join.py's edits of them, a fake Steam folder, a game folder): parses Source (join.cmd copied
# to a .ps1), loads its top-level functions and prints OK or FAIL lines.
param([string]$Source, [string]$Base)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { foreach ($e in $errors) { "FAIL parse: $e" }; exit 2 }
'OK parse'
foreach ($f in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([ScriptBlock]::Create($f.Extent.Text))
}
# join.cmd's own constants for Steam.
foreach ($s in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in @('$steamAppId', '$steamExes', '$steamLauncherArgs', '$steamId64Base', '$launchPath') })) {
    . ([ScriptBlock]::Create($s.Extent.Text))
}
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "OK $Name" } else { "FAIL $Name" } }
$global:Answers = New-Object System.Collections.Queue
function Ask([string]$Question, [string]$Default) {
    if (-not $global:Answers.Count) { throw "not expected: $Question" }
    $answer = $global:Answers.Dequeue()
    if (-not $answer) { return $Default }
    return $answer
}
function Answer([string[]]$List) { $global:Answers.Clear(); foreach ($a in $List) { $global:Answers.Enqueue($a) } }
$global:Said = New-Object System.Collections.ArrayList
function Write-Host { param([Parameter(Position = 0)]$Object, $ForegroundColor) [void]$global:Said.Add("$Object") }
function Read-Bytes([string]$Name) { return [IO.File]::ReadAllBytes((Join-Path $Base $Name)) }
function Read-Utf8([string]$Name) { return (New-Object Text.UTF8Encoding $false).GetString((Read-Bytes $Name)) }
function Same([byte[]]$A, [byte[]]$B) { return $A.Length -eq $B.Length -and [Linq.Enumerable]::SequenceEqual($A, $B) }

# Steam's command line.
$steam = '"C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium\SLauncher.exe" -steam -maintenance'
$words = Split-CommandLine $steam
Check 'split' ($words.Count -eq 3 -and $words[0] -eq 'C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium\SLauncher.exe' -and $words[2] -eq '-maintenance')
$found = Find-SteamGame $steam
Check 'steam game' ($found -and $found.Folder -eq 'C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium' -and $found.Before -eq '' -and $found.Extra.Count -eq 0)
$found = Find-SteamGame ('-Server roe-os.de -Name "Anna Lee" ' + $steam + ' -windowed')
Check 'options and extra' ($found.Before -eq '-Server roe-os.de -Name "Anna Lee"' -and @($found.Extra) -join ',' -eq '-windowed')
$read = Read-Arguments $found.Before
Check 'options read' ($read.Server -eq 'roe-os.de' -and $read.Name -eq 'Anna Lee' -and -not $read.Command)
Check 'no game' ($null -eq (Find-SteamGame '-Server roe-os.de firewall') -and $null -eq (Find-SteamGame ''))
Check 'exe case' ($null -ne (Find-SteamGame 'D:\Games\ROE\europa_client.EXE'))

# The game folder: Steam's, or its XVersion when that was the last one.
$game = Join-Path $Base 'game'
Check 'client base' ((Get-SteamClient $game '') -eq $game)
Check 'client xversion' ((Get-SteamClient $game (Join-Path $game 'XVersion')) -eq (Join-Path $game 'XVersion'))
Check 'client other' ((Get-SteamClient $game (Join-Path $Base 'steam')) -eq $game)

# The Steam profile: the same account id as join.py's.
Check 'account id' ((Get-AccountId ('a' * 64)) -ceq 'ffe054fe7ae0cb6d' -and (Get-AccountId '') -eq '')
$accounts = @([pscustomobject]@{ name = 'Anna'; token = 'a' * 64; last_used = 9 }, [pscustomobject]@{ name = 'Bob'; token = 'b' * 64; last_used = 5 })
$settings = [pscustomobject]@{ servers = @([pscustomobject]@{ address = 'old.example'; last_used = 1 }, [pscustomobject]@{ address = 'new.example'; last_used = 7 }) }
Check 'server last used' ((Get-SteamServer $settings '') -eq 'new.example' -and (Get-SteamServer $settings 'given.example') -eq 'given.example')
$pick = Get-SteamAccount $settings 'new.example' $accounts
Check 'account last used' ($pick.Found -and $pick.Entry.name -eq 'Anna')
$settings | Add-Member -NotePropertyName steam -NotePropertyValue ([pscustomobject]@{ server = 'old.example'; account = (Get-AccountId ('b' * 64)) })
$pick = Get-SteamAccount $settings 'old.example' $accounts
$gone = Get-SteamAccount $settings 'old.example' @($accounts[0])
Check 'profile' ((Get-SteamServer $settings '') -eq 'old.example' -and $pick.Found -and $pick.Entry.name -eq 'Bob' -and -not $gone.Found)

# localconfig.vdf: the same text as join.py's edit, only that key, back to the original.
$sample = Read-Utf8 'sample.vdf'
Check 'read' ($null -eq (Get-LaunchOptions $sample) -and (Get-LaunchOptions $sample '730') -ceq '-novid "quoted" C:\x')
$line = '"C:\Users\A B\Desktop\join.cmd" %command%'
$added = Set-LaunchOptions $sample $line
Check 'set as join.py' ($added -ceq (Read-Utf8 'added.vdf') -and (Get-LaunchOptions $added) -ceq $line)
$changed = Set-LaunchOptions $added '-dx11'
Check 'replace' ((Get-LaunchOptions $changed) -ceq '-dx11' -and $changed -ceq $sample.Replace("`"60437`"`n", "`"60437`"`n`t`t`t`t`t`t`"LaunchOptions`"`t`t`"-dx11`"`n"))
Check 'remove' ((Set-LaunchOptions $changed $null) -ceq $sample -and (Set-LaunchOptions $sample $null) -ceq $sample)
Check 'new block as join.py' ((Set-LaunchOptions (Read-Utf8 'other.vdf') '-x') -ceq (Read-Utf8 'other-added.vdf'))
$crlf = Read-Utf8 'crlf.vdf'
$crlfAdded = Set-LaunchOptions $crlf '-x'
Check 'crlf as join.py' ($crlfAdded -ceq (Read-Utf8 'crlf-added.vdf') -and (Set-LaunchOptions $crlfAdded $null) -ceq $crlf)
$bad = 0
foreach ($damaged in @("`"UserLocalConfigStore`"`n{`n", "`"a`" `"b`" `"c`"`n", '"open', "`"Other`"`n{`n}`n")) {
    try { Set-LaunchOptions $damaged '-x' | Out-Null } catch { $bad++ }
}
Check 'damaged refused' ($bad -eq 4)

# The Steam users: the one that played the game, its name from loginusers.vdf.
$steamFolder = Join-Path $Base 'steam'
$users = @(Get-SteamUsers $steamFolder)
Check 'users' ($users.Count -eq 2 -and $users[0].Id -eq '30642568' -and $users[0].Owns -and $users[0].Name -eq 'Anna' -and -not $users[1].Owns)
Check 'user picked' ((Select-SteamUser $users).Id -eq '30642568')

# steam-setup: refused while Steam runs (nothing written), then set and removed with a backup.
$config = $users[0].Path
$original = [IO.File]::ReadAllBytes($config)
$settingsPath = Join-Path $Base 'roe-join.json'
$env:ROE_JOIN_SELF = 'C:\Users\A B\Desktop\join.cmd'
function Test-SteamRunning { return $true }
Answer @('y')
$refused = ''
try { Invoke-SteamSetup ([pscustomobject]@{ client = '' }) $false '' '' $steamFolder } catch { $refused = $_.Exception.Message }
Check 'steam running' ($refused -like 'Steam is running*' -and (Same $original ([IO.File]::ReadAllBytes($config))) -and -not @(Get-ChildItem -LiteralPath (Split-Path $config) -Filter '*.bak').Count)
Check 'line printed' ($global:Said -contains "  $line")
function Test-SteamRunning { return $false }
Answer @('y')
Invoke-SteamSetup ([pscustomobject]@{ client = '' }) $false '' '' $steamFolder
$text = [IO.File]::ReadAllText($config)
$backups = @(Get-ChildItem -LiteralPath (Split-Path $config) -Filter '*.roe-join.bak')
Check 'set' ((Get-LaunchOptions $text) -ceq $line -and $backups.Count -eq 1 -and (Same $original ([IO.File]::ReadAllBytes($backups[0].FullName))))
Check 'set as join.py' ($text -ceq (Read-Utf8 'added.vdf'))
Answer @('y')
Invoke-SteamSetup ([pscustomobject]@{ client = '' }) $true '' '' $steamFolder
Check 'off' (Same $original ([IO.File]::ReadAllBytes($config)))
[IO.File]::WriteAllText($config, (Set-LaunchOptions $sample '-dx11'))
Answer @('y')
Invoke-SteamSetup ([pscustomobject]@{ client = '' }) $true '' '' $steamFolder
Check 'off keeps others' ((Get-LaunchOptions ([IO.File]::ReadAllText($config))) -ceq '-dx11' -and ($global:Said | Where-Object { $_ -like '*not ours*' }))

# The profile in roe-join.json, kept by Save-JoinSettings.
$joinRoot = Join-Path $Base 'roe-join'
$folder = Get-AccountFolder 'roe-os.de'
Save-Accounts $folder @([pscustomobject]@{ name = 'Anna'; token = 'a' * 64; last_used = 1 }) | Out-Null
Answer @('n')
Invoke-SteamSetup ([pscustomobject]@{ client = '' }) $false 'roe-os.de' 'anna' $steamFolder
$saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
Check 'profile saved' ($saved.steam.server -eq 'roe-os.de' -and $saved.steam.account -ceq 'ffe054fe7ae0cb6d')
Save-JoinSettings $game $true $true '' @()
Check 'profile kept' ((Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).steam.account -ceq 'ffe054fe7ae0cb6d')
Answer @('n')
Invoke-SteamSetup (Read-Settings) $false '' '' $steamFolder
Check 'profile removed' ($null -eq (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).steam)
