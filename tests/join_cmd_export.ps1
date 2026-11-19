# join.cmd's account backup (export, import, merge, a different certificate) in the folder Base:
# parses Source (join.cmd copied to a .ps1), loads its top-level functions and prints OK or FAIL lines.
param([string]$Source, [string]$Base)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { foreach ($e in $errors) { "FAIL parse: $e" }; exit 2 }
foreach ($f in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([ScriptBlock]::Create($f.Extent.Text))
}
foreach ($line in @(Get-Content -LiteralPath $Source | Where-Object { $_ -match '^\$backup(Format|Warning) = ' })) { Invoke-Expression $line }
$global:Answers = New-Object System.Collections.Queue
$global:Asked = New-Object System.Collections.ArrayList
function Ask([string]$Question, [string]$Default) {
    [void]$global:Asked.Add(@($Question, $Default))
    if (-not $global:Answers.Count) { throw "not expected: $Question" }
    $answer = $global:Answers.Dequeue()
    if (-not $answer) { return $Default }
    return $answer
}
function Answer([string[]]$List) { $global:Answers.Clear(); $global:Asked.Clear(); foreach ($a in $List) { $global:Answers.Enqueue($a) } }
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "OK $Name" } else { "FAIL $Name" } }
function Add-Account($List, [string]$Name, [string]$Token, [int64]$Last) { [void]$List.Add([pscustomobject]@{ name = $Name; token = $Token; last_used = $Last }) }
$t1 = 'a' * 64; $t2 = 'b' * 64; $t3 = 'c' * 64; $t4 = 'd' * 64; $t5 = 'e' * 64
$pin1 = '1' * 64; $pin2 = '2' * 64; $pin3 = '3' * 64

# This computer: two servers (one by domain, with a name) and their pins.
$root = Join-Path $Base 'one\roe-join'
$a = New-Object System.Collections.ArrayList
Add-Account $a 'Anna' $t1 50; Add-Account $a 'Ben' $t2 40
Save-Accounts (Join-Path $root 'play.example.org') $a | Out-Null
Set-Content -LiteralPath (Join-Path $root 'play.example.org\server.pin') -Value $pin1
$b = New-Object System.Collections.ArrayList
Add-Account $b 'Cleo' $t3 30
Save-Accounts (Join-Path $root '203.0.113.5') $b | Out-Null
Set-Content -LiteralPath (Join-Path $root '203.0.113.5\server.pin') -Value $pin2
$settings = '{"servers":[{"address":"Play.Example.org","last_used":50,"name":"Europa"},{"address":"203.0.113.5","last_used":30}]}' | ConvertFrom-Json
$file = Join-Path $Base 'backup.json'
$done = Export-Accounts $root $settings $file
$json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
Check 'export counts' ($done.Servers -eq 2 -and $done.Accounts -eq 3)
Check 'export format' ($json.format -eq 'roe-join-accounts' -and $json.version -eq 1 -and $json.servers[0].address -ceq 'Play.Example.org' -and $json.servers[0].name -ceq 'Europa' -and
    $json.servers[0].pin -eq $pin1 -and @($json.servers[0].accounts).Count -eq 2 -and $json.servers[1].accounts[0].token -eq $t3)
Check 'warning names the keys' ($backupWarning -like '*account keys*')

# The other computer: an account of its own, an older copy of Anna, Ben renamed elsewhere, and a
# different pin for the second server.
$other = Join-Path $Base 'two\roe-join'
$c = New-Object System.Collections.ArrayList
Add-Account $c 'Anna' $t1 10; Add-Account $c 'Dora' $t4 99; Add-Account $c 'Ben' $t5 90
Save-Accounts (Join-Path $other 'play.example.org') $c | Out-Null
Set-Content -LiteralPath (Join-Path $other 'play.example.org\server.pin') -Value $pin1
New-Item -ItemType Directory -Force -Path (Join-Path $other '203.0.113.5') | Out-Null
Set-Content -LiteralPath (Join-Path $other '203.0.113.5\server.pin') -Value $pin3
$mine = '{"servers":[{"address":"play.example.org","last_used":99}]}' | ConvertFrom-Json
Answer @('n')
$r = Import-Accounts $other $mine $file
$merged = Read-Accounts (Join-Path $other 'play.example.org')
$anna = @($merged | Where-Object { $_.name -eq 'Anna' })
$ben = @($merged | Where-Object { $_.name -eq 'Ben' })
Check 'merged' ($merged.Count -eq 3 -and $anna[0].last_used -eq 50 -and $ben[0].token -eq $t5 -and @($merged | Where-Object { $_.name -eq 'Dora' }).Count -eq 1)
Check 'counts' ($r.Updated -eq 1 -and $r.Added -eq 0)
Check 'other pin asked, kept' ($global:Asked.Count -eq 1 -and $global:Asked[0][1] -eq 'n' -and (Get-Content -LiteralPath (Join-Path $other '203.0.113.5\server.pin') -Raw).Trim() -eq $pin3 -and
    -not (Test-Path -LiteralPath (Join-Path $other '203.0.113.5\accounts.json')) -and $r.Skipped -contains '203.0.113.5')
Answer @('y')
$r = Import-Accounts $other $mine $file
$second = Read-Accounts (Join-Path $other '203.0.113.5')
Check 'other pin taken when confirmed' ((Get-Content -LiteralPath (Join-Path $other '203.0.113.5\server.pin') -Raw).Trim() -eq $pin2 -and
    $second.Count -eq 1 -and $second[0].name -ceq 'Cleo' -and $r.Added -eq 1)
Check 'servers list' ((@($r.Servers | ForEach-Object { $_.address }) -join ',') -ceq 'play.example.org,203.0.113.5' -and "$($r.Servers[0].name)" -ceq 'Europa')
# Again: nothing new, no question (the pins match now).
Answer @()
$r = Import-Accounts $other $mine $file
Check 'second import changes nothing' ($r.Added -eq 0 -and $r.Updated -eq 0 -and $global:Asked.Count -eq 0)

# A new computer: everything comes over, and an unsafe address or a bad file is refused.
$fresh = Join-Path $Base 'three\roe-join'
$r = Import-Accounts $fresh ([pscustomobject]@{ client = '' }) $file
Check 'fresh computer' ($r.Added -eq 3 -and (Get-Content -LiteralPath (Join-Path $fresh 'play.example.org\server.pin') -Raw).Trim() -eq $pin1 -and $r.Servers[0].address -ceq 'Play.Example.org')
$bad = Join-Path $Base 'bad.json'
Set-Content -LiteralPath $bad -Value ('{"format":"roe-join-accounts","version":1,"servers":[{"address":"..\\..\\x","pin":"","accounts":[{"name":"X","token":"' + $t1 + '","last_used":1}]}]}')
$r = Import-Accounts $fresh ([pscustomobject]@{ client = '' }) $bad
Check 'unsafe address skipped' ($r.Added -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $Base 'x')))
Set-Content -LiteralPath $bad -Value '{"accounts":[]}'
$refused = $false
try { Import-Accounts $fresh ([pscustomobject]@{ client = '' }) $bad | Out-Null } catch { $refused = $_.Exception.Message -like '*no account backup*' }
Check 'other file refused' $refused

# A backup that join.py wrote (prepared by test_join.py) imports here too.
$r = Import-Accounts (Join-Path $Base 'four\roe-join') ([pscustomobject]@{ client = '' }) (Join-Path $Base 'py-backup.json')
$py = Read-Accounts (Join-Path $Base 'four\roe-join\linux.example')
Check 'join.py backup' ($r.Added -eq 1 -and $py[0].name -ceq 'Penny' -and $py[0].token -eq ('f' * 64) -and $r.Servers[0].name -ceq 'Linux EU')
