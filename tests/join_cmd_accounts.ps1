# join.cmd's account functions (menu, accounts.json, login) in the folder Base with a
# fake account service: parses Source (join.cmd copied to a .ps1), loads its top-level functions
# and prints OK or FAIL lines.
param([string]$Source, [string]$Base)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { foreach ($e in $errors) { "FAIL parse: $e" }; exit 2 }
foreach ($f in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([ScriptBlock]::Create($f.Extent.Text))
}
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
# The fake service: replies by request line; $null stands for no answer.
$global:Replies = @{}
$global:Sent = New-Object System.Collections.ArrayList
function Invoke-Account([string]$Ip, [string]$Folder, [string]$Line) {
    [void]$global:Sent.Add($Line)
    if (-not $global:Replies.ContainsKey($Line)) { throw "not expected: $Line" }
    return $global:Replies[$Line]
}
function Serve($Map) { $global:Replies = $Map; $global:Sent.Clear() }
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "OK $Name" } else { "FAIL $Name" } }
$t1 = 'a' * 64; $t2 = 'b' * 64; $t3 = 'c' * 64; $t4 = 'd' * 64

# The menu's selection logic.
$s = Step-Menu 0 'UpArrow' 3
Check 'up wraps' ($s[0] -eq 2 -and -not $s[1])
$s = Step-Menu 2 'DownArrow' 3
Check 'down wraps' ($s[0] -eq 0 -and -not $s[1])
Check 'home end' ((Step-Menu 1 'Home' 3)[0] -eq 0 -and (Step-Menu 0 'End' 3)[0] -eq 2)
$s = Step-Menu 1 'Enter' 3
Check 'enter chooses' ($s[0] -eq 1 -and $s[1])
Check 'other keys' ((Step-Menu 1 'A' 3)[0] -eq 1)
$global:Keys = New-Object System.Collections.Queue
foreach ($k in @('DownArrow', 'DownArrow', 'DownArrow', 'UpArrow', 'Enter')) { $global:Keys.Enqueue($k) }
$global:Drawn = New-Object System.Collections.ArrayList
$picked = Select-MenuWithKeys @('Anna', 'Bob', 'Create a new account') { $global:Keys.Dequeue() } { param($e, $i, $f) [void]$global:Drawn.Add("$i $f") }
Check 'keys pick' ($picked -eq 2 -and $global:Drawn.Count -eq 5 -and $global:Drawn[0] -eq '0 True' -and $global:Drawn[1] -eq '1 False')
Answer @('x', '7', '2')
Check 'numbered list' ((Select-Numbered @('Anna', 'Bob', 'Create a new account')) -eq 1 -and $global:Asked.Count -eq 3)
Answer @('')
Check 'numbered default first' ((Select-Numbered @('Anna', 'Create a new account')) -eq 0)

# accounts.json: the most recently used first; entries without a valid key (and no name) are skipped.
$server = Join-Path $Base 'server'
New-Item -ItemType Directory -Force -Path $server | Out-Null
$rows = @(@{ name = 'anna'; token = $t1; last_used = 2 }, @{ name = 'Bob'; token = $t2; last_used = 3 }, @{ name = 'carl'; token = $t3; last_used = 1 },
    @{ name = 'bad'; token = 'nope'; last_used = 9 }, @{ token = ''; last_used = 9 })
Set-Content -LiteralPath (Join-Path $server 'accounts.json') -Value (@{ accounts = $rows } | ConvertTo-Json -Depth 4) -Encoding UTF8
$list = Read-Accounts $server
Check 'read' ($list.Count -eq 3 -and $list[0].name -eq 'Bob' -and $list[0].token -eq $t2 -and $list[2].name -eq 'carl')
$path = Save-Accounts $server $list
Check 'saved' ((Test-Path -LiteralPath $path) -and (Get-Content -LiteralPath $path -Raw) -match '"accounts":\s*\[')
$list[1].last_used = 50
Save-Accounts $server $list | Out-Null
$again = Read-Accounts $server
Check 'most recent first' ($again.Count -eq 3 -and $again[0].last_used -eq 50 -and $again[1].name -eq 'Bob')
$one = New-Item -ItemType Directory -Force -Path (Join-Path $Base 'one')
$single = New-Object System.Collections.ArrayList
[void]$single.Add([pscustomobject]@{ name = 'Solo'; token = $t4; last_used = 9 })
Save-Accounts $one.FullName $single | Out-Null
$back = Read-Accounts $one.FullName
Check 'one account round trip' ($back.Count -eq 1 -and $back[0].name -eq 'Solo' -and $back[0].last_used -eq 9)

# The menu: saved accounts, then "Create a new account"; -Name picks without it.
Answer @('4')
Check 'menu new account' ($null -eq (Select-Account $again '') -and $global:Asked.Count -eq 1)
Answer @('1')
Check 'menu first' ((Select-Account $again '').token -eq $again[0].token)
Answer @()
Check 'name picks' ((Select-Account $again 'BOB').token -eq $t2 -and $global:Asked.Count -eq 0)
Check 'unknown name is new' ($null -eq (Select-Account $again 'Dora'))
Check 'no accounts, no menu' ($null -eq (Select-Account (New-Object System.Collections.ArrayList) ''))

# Current names from the server; the limit stops the queries.
Serve @{ "NAME $t1" = 'OK Glacier'; "NAME $t2" = 'DENIED'; "NAME $t3" = 'LIMIT' }
$order = @($again | ForEach-Object { $_.token })
$changed = Update-AccountNames '1.2.3.4' $server $again
Check 'names refreshed' ($changed -and @($again | Where-Object { $_.token -eq $t1 })[0].name -eq 'Glacier' -and @($again | Where-Object { $_.token -eq $t2 })[0].name -eq 'Bob')

# LOGIN2 answers the current name; it is saved and the account goes on top.
$work = Join-Path $Base 'login'
$accounts = New-Object System.Collections.ArrayList
[void]$accounts.Add([pscustomobject]@{ name = 'Anna'; token = $t1; last_used = 5 })
[void]$accounts.Add([pscustomobject]@{ name = 'Bob'; token = $t2; last_used = 3 })
Serve @{ "LOGIN2 $t2" = 'OK 123456789012 Bobby One' }
$r = Invoke-Login '1.2.3.4' $work $accounts $accounts[1] ''
Check 'login2 name' ($r.Uid -eq '123456789012' -and $r.Name -eq 'Bobby One' -and $accounts[0].name -eq 'Bobby One' -and (Read-Accounts $work)[0].name -eq 'Bobby One')
# A released name: claimed again, the new key saved.
Serve @{ "LOGIN2 $t1" = 'DENIED'; 'CLAIM Anna' = "OK $t3"; "LOGIN2 $t3" = 'OK 78 Anna' }
$anna = @($accounts | Where-Object { $_.name -eq 'Anna' })[0]
$r = Invoke-Login '1.2.3.4' $work $accounts $anna ''
Check 'reclaimed' ($r.Uid -eq '78' -and $anna.token -eq $t3 -and @(Read-Accounts $work | Where-Object { $_.token -eq $t3 }).Count -eq 1)
Serve @{ "LOGIN2 $t3" = 'BANNED' }
$threw = $false
try { Invoke-Login '1.2.3.4' $work $accounts $anna '' | Out-Null } catch { $threw = $_.Exception.Message -like '*banned*' }
Check 'banned' $threw

# New account, first-login on: the server names it, no question.
Serve @{ 'NEW' = "OK $t4 newaccount1234"; "LOGIN2 $t4" = 'OK 90 newaccount1234' }
Answer @()
$r = Invoke-Login '1.2.3.4' $work $accounts $null ''
Check 'new, first-login on' ($r.Uid -eq '90' -and $r.Name -eq 'newaccount1234' -and $accounts.Count -eq 3 -and @(Read-Accounts $work | Where-Object { $_.token -eq $t4 }).Count -eq 1 -and $global:Asked.Count -eq 0)
# First-login off: a name is asked, a taken one again.
$off = Join-Path $Base 'off'
$accounts = New-Object System.Collections.ArrayList
$t5 = 'e' * 64
Serve @{ 'NEW' = 'NAME-REQUIRED'; 'CLAIM Anna' = 'TAKEN'; 'CLAIM Anja' = "OK $t5"; "LOGIN2 $t5" = 'OK 91 Anja' }
Answer @('Anna', 'Anja')
$r = Invoke-Login '1.2.3.4' $off $accounts $null ''
Check 'new, first-login off' ($r.Name -eq 'Anja' -and $global:Asked.Count -eq 2 -and (Read-Accounts $off)[0].token -eq $t5)
# -Name for a new account claims it directly.
$t7 = '0' * 64
Serve @{ 'CLAIM Carl' = "OK $t7"; "LOGIN2 $t7" = 'OK 93 Carl' }
Answer @()
$r = Invoke-Login '1.2.3.4' $off $accounts $null 'Carl'
Check 'name claims' ($r.Name -eq 'Carl' -and $global:Sent[0] -eq 'CLAIM Carl')
# No account service: the name for the plain name registration.
Serve @{ 'NEW' = $null }
Answer @('Dora')
$r = Invoke-Login '1.2.3.4' $off $accounts $null ''
Check 'no service' ($null -eq $r.Uid -and $r.Name -eq 'Dora')
# The plain name is saved without a key and offered next time; picking it registers it again.
$saved = Read-Accounts $off
Check 'plain name saved' ($saved[0].name -eq 'Dora' -and -not $saved[0].token)
Serve @{ 'CLAIM Dora' = $null }
Answer @()
$r = Invoke-Login '1.2.3.4' $off $saved $saved[0] ''
Check 'plain name again' ($null -eq $r.Uid -and $r.Name -eq 'Dora' -and @(Read-Accounts $off | Where-Object { $_.name -eq 'Dora' }).Count -eq 1)
# Once the server has accounts, the saved name is claimed and gets its key.
$t8 = 'e' * 64
Serve @{ 'CLAIM Dora' = "OK $t8"; "LOGIN2 $t8" = 'OK 94 Dora' }
$saved = Read-Accounts $off
$r = Invoke-Login '1.2.3.4' $off $saved @($saved | Where-Object { $_.name -eq 'Dora' })[0] ''
Check 'plain name claimed' ($r.Uid -eq '94' -and @(Read-Accounts $off | Where-Object { $_.name -eq 'Dora' -and $_.token -eq $t8 }).Count -eq 1 -and @(Read-Accounts $off | Where-Object { $_.name -eq 'Dora' }).Count -eq 1)
# The login step: with a service the ticket, without one the name on the lobby port and uid 1.
$global:Lobby = $null
function Register-LobbyName([string]$Ip, [string]$Name) { $global:Lobby = $Name }
Serve @{ 'CLAIM Dora' = $null; "LOGIN2 $t8" = 'OK 95 Dora' }
$saved = Read-Accounts $off
$r = Connect-Account '1.2.3.4' $off $saved @($saved | Where-Object { $_.name -eq 'Dora' })[0] ''
Check 'login step' ($r.Uid -eq '95' -and $r.Accounts -and $r.Name -eq 'Dora' -and $null -eq $global:Lobby)
Serve @{ 'NEW' = $null }
Answer @('Erik')
$r = Connect-Account '1.2.3.4' $off (Read-Accounts $off) $null ''
Check 'login step without a service' ($r.Uid -eq '1' -and -not $r.Accounts -and $r.Name -eq 'Erik' -and $global:Lobby -eq 'Erik')
