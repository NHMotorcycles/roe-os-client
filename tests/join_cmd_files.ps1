# join.cmd's game file check against the fake game folder test_join.py made in Base (original
# files, then changed, missing and added ones; the hash cache): parses Source (join.cmd copied to
# a .ps1), loads its top-level functions and prints OK or FAIL lines.
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
# join.cmd's own lists: the real install's sizes and hashes.
foreach ($s in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in @('$originalFiles', '$originalVoiceSha', '$addedFiles') })) {
    . ([ScriptBlock]::Create($s.Extent.Text))
}
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "OK $Name" } else { "FAIL $Name" } }
Check 'lists' ($originalFiles.Count -eq 7 -and @($originalFiles | Where-Object { $_.Sha -notmatch '^[0-9a-f]{64}$' -or $_.Size -le 0 }).Count -eq 0 -and
    $originalVoiceSha.Count -eq 2 -and $addedFiles -contains 'dinput8.dll' -and $addedFiles -contains 'data_exp.vfs')

$voiceFile = 'GCloudVoice.dll'
$voiceBackups = Join-Path $Base 'backups'
$verifyHint = 'Steam: verify'
$fileCheckPath = Join-Path $Base 'appdata\file-check.json'
$game = Join-Path $Base 'game'
$xversion = Join-Path $game 'XVersion'
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
function Write-Host { param([Parameter(Position = 0)]$Object, $ForegroundColor) [void]$global:Said.Add("$Object") }
$global:Said = New-Object System.Collections.ArrayList

# The fake install's files are the originals here.
$originalFiles = @(foreach ($rel in @('SFC\Common.sfc', 'SFC\UI.sfc', 'data_dyn.sfc', 'Cache\otherbin.sfc')) {
    $path = Join-Path $game $rel
    @{ Path = $rel; Size = (Get-Item -LiteralPath $path).Length; Sha = Get-Sha256 $path }
})
$originalVoiceSha = @((Get-Sha256 (Join-Path $game $voiceFile)), (Get-Sha256 (Join-Path $xversion $voiceFile)))
function Changed { return @(Get-ChangedGameFiles $game) }

Check 'original: nothing found' ((Changed).Count -eq 0)
$cache = Get-Content -LiteralPath $fileCheckPath -Raw | ConvertFrom-Json
$key = (Join-Path $game 'SFC\UI.sfc').ToLowerInvariant()
Check 'cache written' (@($cache.files.PSObject.Properties).Count -eq 5 -and $cache.files.$key.sha256 -eq $originalFiles[1].Sha -and
    [int64]$cache.files.$key.size -eq $originalFiles[1].Size -and [int64]$cache.files.$key.time -eq (Get-Item -LiteralPath (Join-Path $game 'SFC\UI.sfc')).LastWriteTimeUtc.Ticks)
$written = (Get-Item -LiteralPath $fileCheckPath).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
Check 'cache unchanged: not written again' ((Changed).Count -eq 0 -and (Get-Item -LiteralPath $fileCheckPath).LastWriteTimeUtc -eq $written)

# The cache is trusted while size and time are the same: a wrong hash there counts.
$cache.files.$key.sha256 = '0' * 64
$cache | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fileCheckPath -Encoding UTF8
Check 'cache used' ((@(Changed) -join '|') -eq 'SFC\UI.sfc changed')
Remove-Item -LiteralPath $fileCheckPath
Check 'no cache: hashed again' ((Changed).Count -eq 0 -and (Test-Path -LiteralPath $fileCheckPath))
Set-Content -LiteralPath $fileCheckPath -Value 'not json'
Check 'damaged cache: hashed again' ((Changed).Count -eq 0 -and ((Get-Content -LiteralPath $fileCheckPath -Raw) -match 'sha256'))

# Changed in place with the same size (as an appended block that rewrites itself): the time
# differs, so it is hashed again.
$ui = Join-Path $game 'SFC\UI.sfc'
$bytes = [IO.File]::ReadAllBytes($ui); $bytes[3] = $bytes[3] -bxor 1; [IO.File]::WriteAllBytes($ui, $bytes)
(Get-Item -LiteralPath $ui).LastWriteTimeUtc = (Get-Date).AddMinutes(1).ToUniversalTime()
Check 'same size, other content' ((@(Changed) -join '|') -eq 'SFC\UI.sfc changed')
$bytes[3] = $bytes[3] -bxor 1; [IO.File]::WriteAllBytes($ui, $bytes)
Check 'restored' ((Changed).Count -eq 0)
# A block appended (another size): changed without hashing.
$common = Join-Path $game 'SFC\Common.sfc'
$keep = [IO.File]::ReadAllBytes($common)
[IO.File]::WriteAllBytes($common, $keep + [byte[]](1, 2, 3))
$commonKey = $common.ToLowerInvariant()
Check 'appended' ((@(Changed) -join '|') -eq 'SFC\Common.sfc changed' -and [int64](Get-Content -LiteralPath $fileCheckPath -Raw | ConvertFrom-Json).files.$commonKey.size -eq $keep.Length)
[IO.File]::WriteAllBytes($common, $keep)
Move-Item -LiteralPath (Join-Path $game 'data_dyn.sfc') -Destination (Join-Path $Base 'data_dyn.sfc')
Check 'missing' ((@(Changed) -join '|') -eq 'data_dyn.sfc missing')
Move-Item -LiteralPath (Join-Path $Base 'data_dyn.sfc') -Destination (Join-Path $game 'data_dyn.sfc')

# Added files: a proxy DLL and the overlay archive; folders of other tools are no problem.
Set-Content -LiteralPath (Join-Path $game 'dinput8.dll') -Value 'proxy'
Set-Content -LiteralPath (Join-Path $game 'data_exp.vfs') -Value 'overlay'
New-Item -ItemType Directory -Path (Join-Path $game 'backup-of-another-tool') | Out-Null
$found = @(Changed)
Check 'added' (($found -join '|') -eq 'data_exp.vfs added|dinput8.dll added')
$text = @(Get-GameFilesText $found $game)
Check 'added: delete, no verify' ($text.Count -eq 3 -and $text[0] -like 'Your game files were changed by another launcher (data_exp.vfs added, dinput8.dll added)*' -and
    $text[1] -eq "Delete data_exp.vfs, dinput8.dll in $game (not part of the game; Steam's check leaves them)." -and $text[2] -eq 'Then start again.')
Remove-Item -LiteralPath (Join-Path $game 'dinput8.dll'), (Join-Path $game 'data_exp.vfs')

# GCloudVoice.dll: the original, ours while voice chat is on (the backup record), not another one.
$dll = Join-Path $game $voiceFile
$original = [IO.File]::ReadAllBytes($dll)
$oursBytes = [Text.Encoding]::ASCII.GetBytes('our voice dll')
[IO.File]::WriteAllBytes($dll, $oursBytes)
Check 'voice: another DLL' ((@(Changed) -join '|') -eq 'GCloudVoice.dll changed')
$record = Get-VoiceBackupFolder $game
New-Item -ItemType Directory -Force -Path $record | Out-Null
[pscustomobject]@{ folder = $game; original = $originalVoiceSha[0]; installed = (Get-Sha256 $dll) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $record 'backup.json')
Check 'voice: ours' ((Changed).Count -eq 0)
[IO.File]::WriteAllBytes($dll, $original)
Remove-Item -LiteralPath $dll
Check 'voice: missing' ((@(Changed) -join '|') -eq 'GCloudVoice.dll missing')
[IO.File]::WriteAllBytes($dll, $original)

# XVersion: the main folder's files, its own GCloudVoice.dll (the other original) and added files in both.
Check 'xversion: original' (@(Get-ChangedGameFiles $xversion).Count -eq 0 -and @(Get-ChangedGameFiles ($xversion + '\')).Count -eq 0)
Set-Content -LiteralPath (Join-Path $xversion 'version.dll') -Value 'proxy'
[IO.File]::WriteAllBytes((Join-Path $xversion $voiceFile), $oursBytes)
Set-Content -LiteralPath (Join-Path $game 'SFC\UI.sfc') -Value 'patched'
$found = @(Get-ChangedGameFiles $xversion)
Check 'xversion: changed' (($found -join '|') -eq 'SFC\UI.sfc changed|XVersion\GCloudVoice.dll changed|XVersion\version.dll added')
$text = @(Get-GameFilesText $found $xversion)
Check 'xversion: text' ($text.Count -eq 4 -and $text[1] -eq 'Verify them in Steam: verify.' -and $text[2] -eq "Delete XVersion\version.dll in $game (not part of the game; Steam's check leaves them).")
Check 'main folder: its own voice DLL' ((@(Changed) -join '|') -eq 'SFC\UI.sfc changed')
$many = @(Get-GameFilesText @('a changed', 'b changed', 'c changed', 'd changed', 'e missing', 'f changed') $game)
Check 'more than four' ($many[0] -like '*(a changed, b changed, c changed, d changed, and 2 more)*' -and $many.Count -eq 3)

# The question: no stops, yes starts anyway, nothing asked for original files or with the option.
Answer @('n')
$stop = ''
try { Confirm-GameFiles $xversion $false } catch { $stop = $_.Exception.Message }
Check 'confirm: no' ($stop -like 'Cancelled: the game files are not the original ones*' -and $global:Asked.Count -eq 1 -and $global:Asked[0][0] -eq 'Start the game anyway? (y/n)' -and
    $global:Asked[0][1] -eq 'n' -and $global:Said -contains 'Then start again.')
Answer @('y')
$stop = ''
try { Confirm-GameFiles $xversion $false } catch { $stop = $_.Exception.Message }
Check 'confirm: start anyway' (-not $stop -and $global:Asked.Count -eq 1)
Answer @(); $global:Said.Clear()
Confirm-GameFiles $xversion $true
Check 'confirm: skipped' ($global:Asked.Count -eq 0 -and $global:Said[0] -like '*skipped (--skip-file-check)*')
Remove-Item -LiteralPath (Join-Path $xversion 'version.dll')
[IO.File]::WriteAllBytes((Join-Path $xversion $voiceFile), [IO.File]::ReadAllBytes((Join-Path $Base 'xversion-voice.dll')))
Set-Content -LiteralPath (Join-Path $game 'SFC\UI.sfc') -Value 'ui archive' -NoNewline
Answer @()
Confirm-GameFiles $xversion $false
Check 'confirm: original, nothing asked' ($global:Asked.Count -eq 0)
