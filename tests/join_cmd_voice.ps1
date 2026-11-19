# join.cmd's voice DLL functions against the fake folders test_join.py made in Base: parses
# Source (join.cmd copied to a .ps1), loads its top-level functions and prints OK or FAIL lines.
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
$voiceFile = 'GCloudVoice.dll'
$voiceBackupName = 'roe-join-backup'
$voiceSource = Join-Path $Base 'package\voice'
$joinFolder = Join-Path $Base 'package'
$voiceBackups = Join-Path $Base 'backups'
$verifyHint = 'verify'
$game = Join-Path $Base 'game'
$ours = Join-Path $voiceSource $voiceFile
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
function Bytes([string]$Path) { return [IO.File]::ReadAllBytes($Path) }
$oursHash = Get-Sha256 $ours

Check 'problem ours' ((Get-VoiceDllProblem $ours $game) -eq '')
Check 'problem original' ((Get-VoiceDllProblem (Join-Path $Base 'copy\GCloudVoice.dll') $game) -like "*the game's original*")
Check 'problem game folder' ((Get-VoiceDllProblem (Join-Path $game $voiceFile) $game) -like '*game folder*')
Check 'problem 32-bit' ((Get-VoiceDllProblem (Join-Path $Base 'x86\GCloudVoice.dll') $game) -like '*64-bit*')
Check 'problem no export' ((Get-VoiceDllProblem (Join-Path $Base 'noexport\GCloudVoice.dll') $game) -like '*GetVoiceEngine*')
Check 'problem missing' ((Get-VoiceDllProblem (Join-Path $Base 'gone\GCloudVoice.dll') $game) -like '*not found*')

Answer @()
$r = Select-VoiceDll $ours $game $false
Check 'saved path used' ($r.Hash -eq $oursHash -and -not $r.Asked -and $global:Asked.Count -eq 0)

# Nothing next to the script either: the folder is asked for.
$realSource = $voiceSource; $realFolder = $joinFolder; $voiceSource = Join-Path $Base 'nowhere'; $joinFolder = Join-Path $Base 'nowhere'
Answer @((Join-Path $Base 'nothing'), ('"' + $realSource + '"'))
$r = Select-VoiceDll (Join-Path $Base 'gone\GCloudVoice.dll') $game $false
Check 'missing asks for the folder' ($r.Hash -eq $oursHash -and $r.Asked -and $r.Dll -eq $ours -and $global:Asked.Count -eq 2 -and $global:Asked[0][0] -like 'Folder with our*')

Answer @('')
$r = Select-VoiceDll (Join-Path $Base 'gone\GCloudVoice.dll') $game $false
Check 'missing, nothing entered' ($null -eq $r.Hash -and -not $r.Asked)
$voiceSource = $realSource; $joinFolder = $realFolder

Answer @('')
$r = Select-VoiceDll $ours $game $true
Check 'on asks again' ($r.Hash -eq $oursHash -and $global:Asked.Count -eq 1 -and $global:Asked[0][1] -eq $ours)

# No hash file needed: any DLL of ours is used without a question.
$nohash = Join-Path $Base 'nohash\GCloudVoice.dll'
Answer @()
$r = Select-VoiceDll $nohash $game $false
Check 'no hash file, no question' ($r.Hash -eq (Get-Sha256 $nohash) -and $global:Asked.Count -eq 0)

# The first start: voice is on by default, a yes with the DLL found is saved (full path) and
# not asked again; a missing saved DLL asks for the folder; a no is saved; a yes without a DLL
# asks again next time.
Answer @('')
$c = Get-VoiceChoice $null '' $game ''
Check 'first start: yes by default, saved' ($c.Voice -eq $true -and $c.Dll -eq $ours -and $c.Pick.Hash -eq $oursHash -and $global:Asked.Count -eq 1 -and $global:Asked[0][1] -eq 'y')
Answer @()
$c = Get-VoiceChoice $c.Voice $c.Dll $game ''
Check 'next start: not asked' ($c.Voice -eq $true -and $c.Pick.Hash -eq $oursHash -and $global:Asked.Count -eq 0)
$realSource = $voiceSource; $realFolder = $joinFolder; $voiceSource = Join-Path $Base 'nowhere'; $joinFolder = Join-Path $Base 'nowhere'
Answer @($realSource)
$c = Get-VoiceChoice $true (Join-Path $Base 'gone\GCloudVoice.dll') $game ''
Check 'saved file gone: asks for the folder, saves it' ($c.Voice -eq $true -and $c.Dll -eq $ours -and $global:Asked.Count -eq 1 -and $global:Asked[0][0] -like 'Folder with our*')
Answer @('')
$c = Get-VoiceChoice $true (Join-Path $Base 'gone\GCloudVoice.dll') $game ''
Check 'saved file gone, nothing entered: stays on, no voice now' ($c.Voice -eq $true -and $null -eq $c.Pick)
$voiceSource = $realSource; $joinFolder = $realFolder
# The saved file gone but one next to the script: that one, without a question.
Answer @()
$c = Get-VoiceChoice $true (Join-Path $Base 'gone\GCloudVoice.dll') $game ''
Check 'saved file gone, the one in the voice folder taken' ($c.Voice -eq $true -and $c.Dll -eq $ours -and $global:Asked.Count -eq 0)
Answer @('n')
$c = Get-VoiceChoice $null '' $game ''
Check 'no is saved' ($c.Voice -eq $false -and $null -eq $c.Pick)
Answer @()
$c = Get-VoiceChoice $false '' $game ''
Check 'no: not asked again' ($c.Voice -eq $false -and $global:Asked.Count -eq 0)
$saved = $voiceSource; $savedJoin = $joinFolder
$voiceSource = Join-Path $Base 'nowhere'; $joinFolder = Join-Path $Base 'nowhere'
Answer @('y', '')
$c = Get-VoiceChoice $null '' $game ''
Check 'yes without a DLL: asked again next start' ($null -eq $c.Voice -and $null -eq $c.Pick -and $global:Asked.Count -eq 2)
$voiceSource = $saved; $joinFolder = $savedJoin

$copy = Join-Path $Base 'copy\GCloudVoice.dll'
$copyHash = Get-Sha256 $copy
Answer @('')
$r = Select-VoiceDll $copy $game $false
Check 'original refused in select' ($null -eq $r.Hash)
Check 'original refused in install' (-not (Install-Voice $game $copy $copyHash))
Check 'changed since chosen refused' (-not (Install-Voice $game $ours 'another hash'))

$before = Get-Sha256 (Join-Path $game $voiceFile)
Check 'install' ((Install-Voice $game $ours $oursHash) -and (Get-Sha256 (Join-Path $game $voiceFile)) -eq $oursHash)
Check 'backup in the game folder' ((Get-Sha256 (Join-Path $game 'roe-join-backup\GCloudVoice.dll')) -eq $before -and (Test-Path -LiteralPath (Join-Path $game 'roe-join-backup\README.txt')))
Check 'backup original refused' ((Get-VoiceDllProblem $copy $game) -like "*the game's original*")
Check 'restore' ((Restore-Voice $game) -and (Get-Sha256 (Join-Path $game $voiceFile)) -eq $before)
# The game's DLL deleted by hand: the start puts the original back; voice on puts ours in.
Remove-Item -LiteralPath (Join-Path $game $voiceFile)
Check 'missing, restored at start' ((Restore-Voice $game) -and (Get-Sha256 (Join-Path $game $voiceFile)) -eq $before)
Remove-Item -LiteralPath (Join-Path $game $voiceFile)
Check 'missing, ours put in' ((Install-Voice $game $ours $oursHash) -and (Get-Sha256 (Join-Path $game $voiceFile)) -eq $oursHash)
Check 'missing, original back on exit' ((Restore-Voice $game) -and (Get-Sha256 (Join-Path $game $voiceFile)) -eq $before)
# The DLL right next to join.cmd (no voice folder): found without a path question.
$beside = Join-Path $Base 'beside'
New-Item -ItemType Directory -Force -Path $beside | Out-Null
Copy-Item -LiteralPath $ours -Destination (Join-Path $beside $voiceFile)
$savedFolder = $joinFolder; $savedSource = $voiceSource
$joinFolder = $beside; $voiceSource = Join-Path $Base 'nowhere'
Answer @('')
$c = Get-VoiceChoice $null '' $game ''
Check 'beside the script, only yes/no asked' ($c.Voice -and $c.Dll -eq [IO.Path]::GetFullPath((Join-Path $beside $voiceFile)) -and $global:Asked.Count -eq 1)
Answer @()
$c = Get-VoiceChoice $true '' $game ''
Check 'beside the script, nothing asked later' ($c.Voice -and $global:Asked.Count -eq 0)
$joinFolder = $savedFolder; $voiceSource = $savedSource
