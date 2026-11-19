<# : batch part: runs the PowerShell code below from this same file
@echo off
setlocal
set "ROE_JOIN_SELF=%~f0"
set "ROE_JOIN_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create((Get-Content -LiteralPath $env:ROE_JOIN_SELF -Raw)))"
set "ROE_JOIN_EXIT=%ERRORLEVEL%"
if not "%ROE_JOIN_EXIT%"=="0" (
  echo.
  pause
)
exit /b %ROE_JOIN_EXIT%
#>

# Join a Ring of Elysium 2022 server (roe_server) as a player.
#
# This one file is all a player needs besides the game. Double-click it. It asks for
#   - the game folder (the last one is the default),
#   - the server (arrow keys and Enter; the servers joined before by name and address, the most
#     recently used on top, the last entry asks for another address),
#   - the account to play with (arrow keys and Enter; the most recently used on top, the last
#     entry creates a new one),
# then keeps the game from reaching anything but the servers joined so far and the addresses
# each server names for its matches (Windows Firewall, asks for administrator approval only
# when the allowed addresses change), logs in to the server and starts the game. Answers are remembered in %APPDATA%\roe-join.json (the servers with their name and last use
# in "servers"). join.cmd -Server <address> joins that server without the menu.
#
# Accounts: a new account gets a secret key from the server. The keys are kept with each
# account's current name in %APPDATA%\roe-join\<server>\accounts.json; copy that folder to play
# with the same accounts on another computer. With first-login on, the server names a new
# account (newaccount and 4 digits, for example newaccount1234) and the game asks for the real
# name; otherwise join.cmd asks for it. join.cmd -Name <name> picks the saved account of that
# name, or claims the name for a new one, without the menu. The server's certificate is
# remembered on first contact (server.pin there) and a different one is refused.
#
# The firewall rules are optional (asked once). From a command prompt:
#   join.cmd firewall          shows the rules, the trusted servers, whether Windows applies them
#                              and where a running game is connected
#   join.cmd firewall on|off   rules from the next join on, or none (removes this folder's rules)
#   join.cmd firewall reset    removes the rules of every game folder and forgets the servers;
#                              the next join trusts only its own server
# After the step join.cmd checks that the rules apply and that no block rule of another program
# names the game (those are removed with the step). When something is wrong (the prompt declined
# or never shown, the step failed, a policy rule) it says what to do and asks before the game
# starts. Run as administrator, it sets the rules without a prompt.
#
# Voice chat (on by default, asked once; join.cmd voice on|off changes it): our GCloudVoice.dll
# replaces the game's while the game runs. It comes from voice\ next to this file, or from the
# folder the player gave (asked when it is missing and by join.cmd voice on; saved as voice_dll,
# then used without asking). The original is kept with its hash in
# %APPDATA%\roe-join\voice-backup\ and put back when the game exits, or at the next start after a
# crash or a closed window.
#
# The server can name the oldest version of this script it takes (VERSION); an older one stops
# before the game starts and says where to get the new one.
#
# Account backup: join.cmd export [FILE] writes every server's accounts (their keys), certificate
# pin and name into one file (default roe-join-accounts.json here); join.cmd import FILE merges
# one into this computer. join.py reads and writes the same file (--export, --import).
#
# Nothing else in the game folder is changed.
#
# join-gui.cmd is the same in a window: it loads the functions of this file (the steps of a join
# are functions for that), so keep both in one folder.

$ErrorActionPreference = 'Stop'
# Tested Europa_Client.exe builds of 2022-0.2.989.0 x64: the root folder (DX11) and XVersion (DX12).
$expectedSha = @('2dca9b1e122e21363e14eeeb2372598c773205a907ed8d2b2d54a7229ad6ba18', 'e076dddcab4b48d52b920a84bbee125c8b452900ae90cea2f190f2e3654ff81d')
# This script's version; the server can ask for a newer one (VERSION). The same number as join.py's
# and roe_server's (src/lobby/accounts.hpp kJoinScriptVersion).
$joinVersion = '0.9'
$joinUrl = 'https://github.com/mschnati/roe-os-client'
$lobbyPort = 8001
$accountPort = 8002
$settingsPath = Join-Path $env:APPDATA 'roe-join.json'
$joinRoot = Join-Path $env:APPDATA 'roe-join'

# roe-join.json as join.cmd and join-gui.cmd write it.
function Save-JoinSettings([string]$Client, $Firewall, $Voice, $VoiceDll, $Servers) {
    [pscustomobject]@{ client = $Client; firewall = $Firewall; voice = $Voice; voice_dll = $VoiceDll; servers = @($Servers) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}
function Read-Settings {
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $read = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            $read.PSObject.Properties.Remove('voice_dll_sha256')  # no longer used
            return $read
        } catch { }
    }
    return [pscustomobject]@{ client = ''; firewall = $null; voice = $null }
}
function Ask([string]$Question, [string]$Default) {
    $suffix = ''
    if ($Default) { $suffix = " [$Default]" }
    $answer = (Read-Host ($Question + $suffix)).Trim().Trim('"')
    if (-not $answer) { return $Default }
    return $answer
}
function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose() }
}
function Test-Client([string]$Folder) {
    return $Folder -and (Test-Path -LiteralPath (Join-Path $Folder 'Europa_Client.exe') -PathType Leaf)
}
function ConvertTo-Dotted([uint32]$Number) {
    return '{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255)
}
# Everything but this computer and the given addresses (the servers the game may reach), as
# remote address ranges: the rules name no ports, so any port a server uses is allowed.
function Get-BlockedRanges([string[]]$Servers) {
    $allowed = @($Servers | Where-Object { $_ -notmatch ':' } | ForEach-Object {
        $bytes = [Net.IPAddress]::Parse($_).GetAddressBytes()
        [uint32](([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3])
    } | Sort-Object -Unique)
    $ranges = @()
    foreach ($span in @(@([uint32]0, [uint32]2130706431), @([uint32]2147483648, [uint32]4294967295))) {
        [uint64]$low = $span[0]; [uint64]$high = $span[1]
        foreach ($server in $allowed) {
            if ($server -lt $low -or $server -gt $high) { continue }
            if ($server -gt $low) { $ranges += (ConvertTo-Dotted ([uint32]$low)) + '-' + (ConvertTo-Dotted ([uint32]($server - 1))) }
            $low = [uint64]$server + 1
        }
        if ($low -le $high) { $ranges += (ConvertTo-Dotted ([uint32]$low)) + '-' + (ConvertTo-Dotted ([uint32]$high)) }
    }
    # IPv6: everything but ::1, the IPv6 servers and the IPv4 servers' NAT64 addresses
    # (64:ff9b::a.b.c.d), for networks that reach IPv4 servers only through NAT64. The addresses
    # as 32 hex digits, so text order is number order.
    $open6 = [string[]]@(@($allowed | ForEach-Object { '0064ff9b0000000000000000' + $_.ToString('x8') }) +
        @($Servers | Where-Object { $_ -match ':' } | ForEach-Object { ConvertTo-Number6 $_ }) | Select-Object -Unique)
    [Array]::Sort($open6, [StringComparer]::Ordinal)
    $from = '00000000000000000000000000000002'
    foreach ($open in $open6) {
        if ([string]::CompareOrdinal($open, $from) -lt 0) { continue }
        if ([string]::CompareOrdinal($open, $from) -gt 0) { $ranges += (ConvertTo-Text6 $from) + '-' + (ConvertTo-Text6 (Step-Number6 $open -1)) }
        $from = Step-Number6 $open 1
    }
    if ($from) { $ranges += (ConvertTo-Text6 $from) + '-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff' }
    return $ranges
}
# An IPv6 address as 32 hex digits.
function ConvertTo-Number6([string]$Address) {
    return (-join ([Net.IPAddress]::Parse($Address).GetAddressBytes() | ForEach-Object { $_.ToString('x2') }))
}
# Number (32 hex digits) plus or minus one; '' past ffff...ffff.
function Step-Number6([string]$Number, [int]$By) {
    $bytes = [byte[]](0..15 | ForEach-Object { [Convert]::ToByte($Number.Substring($_ * 2, 2), 16) })
    for ($i = 15; $i -ge 0; $i--) {
        $value = [int]$bytes[$i] + $By
        $bytes[$i] = [byte](($value + 256) % 256)
        if ($value -ge 0 -and $value -le 255) { return (-join ($bytes | ForEach-Object { $_.ToString('x2') })) }
    }
    return ''
}
# All eight groups, no "::" (the firewall reads that too).
function ConvertTo-Text6([string]$Number) {
    return ((0..7 | ForEach-Object { [Convert]::ToInt32($Number.Substring($_ * 4, 4), 16).ToString('x') }) -join ':')
}
# An IPv4 or IPv6 address as text (an IPv4-mapped one as IPv4); $null for anything else, loopback,
# the unspecified, multicast or broadcast address.
function ConvertTo-CanonicalAddress([string]$Word) {
    if ($Word -notmatch '^[0-9a-fA-F.:]{2,45}$') { return $null }
    if ($Word -notmatch ':' -and $Word -notmatch '^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$') { return $null }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Word, [ref]$parsed)) { return $null }
    if ($parsed.IsIPv4MappedToIPv6) { $parsed = $parsed.MapToIPv4() }
    $text = $parsed.ToString()
    if ([Net.IPAddress]::IsLoopback($parsed) -or $parsed.IsIPv6Multicast -or $text -in @('0.0.0.0', '::', '255.255.255.255')) { return $null }
    if ($parsed.AddressFamily -eq 'InterNetwork' -and ($parsed.GetAddressBytes()[0] -band 240) -eq 224) { return $null }
    return $text
}
# The ADDRESSES answer: where else the game goes for this server (its matches on other machines),
# each once, at most 64; $null without an OK (no answer or the limit). Other words are skipped.
function Get-ServerAddresses([string]$Reply) {
    if ($Reply -cne 'OK' -and -not $Reply.StartsWith('OK ', [StringComparison]::Ordinal)) { return $null }
    $found = New-Object System.Collections.ArrayList
    foreach ($word in ($Reply.Substring(2) -split ' ')) {
        $address = ConvertTo-CanonicalAddress $word
        if ($address -and -not $found.Contains($address) -and $found.Count -lt 64) { [void]$found.Add($address) }
    }
    return ,[string[]]@($found)
}
# The trusted servers after a join: the earlier ones (Trusted) with this server's own addresses
# (ServerIps) and the ones it lists (Listed; $null without an answer: nothing is dropped). What
# it listed before (Previous) and lists no more goes, and so do its own earlier addresses
# (PreviousIps: a domain that moved), unless another saved server needs them (Kept).
function Get-TrustedUpdate([string[]]$Trusted, [string[]]$ServerIps, $Listed, [string[]]$Previous, [string[]]$Kept, [string[]]$PreviousIps) {
    $candidates = @($PreviousIps)
    if ($null -ne $Listed) { $candidates += @($Previous) }
    $drop = @($candidates | Where-Object { $_ -and $Listed -notcontains $_ -and $ServerIps -notcontains $_ -and $Kept -notcontains $_ })
    return ,[string[]]@(@($Trusted) + @($ServerIps) + @($Listed) |
        Where-Object { $_ -and $drop -notcontains $_ -and $_ -notlike '127.*' -and $_ -ne '::1' } | Sort-Object -Unique)
}
# What other saved servers need: the addresses they list, their own addresses and an address given
# as IP.
function Get-KeptAddresses($Servers, [string]$Address) {
    $key = Get-ServerFolderName $Address
    $kept = @()
    foreach ($s in @($Servers | Where-Object { $_ -and (Get-ServerFolderName $_.address) -ne $key })) {
        $kept += @($s.addresses) + @($s.ips) + @(ConvertTo-CanonicalAddress ("$($s.address)" -replace ':8001$', ''))
    }
    return ,[string[]]@($kept | Where-Object { $_ } | Sort-Object -Unique)
}
# True when a folder's rules (Own) cover its programs, are on and trust exactly Desired.
function Test-RulesCurrent($Own, [int]$ProgramCount, [string[]]$Desired) {
    $Own = @($Own | Where-Object { $_ })
    if (-not $Own.Count -or $Own.Count -ne $ProgramCount -or @($Own | Where-Object { "$($_.Enabled)" -ne 'True' }).Count) { return $false }
    return (@(Get-TrustedServers $Own | Sort-Object -Unique) -join ' ') -eq (@($Desired | Sort-Object -Unique) -join ' ')
}

# --- Firewall -------------------------------------------------------------------------------
function Get-FirewallGroup([string]$Client) {
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Client.ToLowerInvariant()))
    return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12)
}
# The executables of a game folder; subfolders with a game of their own (XVersion in the main
# folder) get their own rules.
function Get-GamePrograms([string]$Client) {
    $nested = @(Get-ChildItem -LiteralPath $Client -Recurse -File -Filter 'Europa_Client.exe' | Where-Object { $_.DirectoryName -ne $Client } | ForEach-Object { $_.DirectoryName + '\' })
    return @(Get-ChildItem -LiteralPath $Client -Recurse -File -Filter '*.exe' | ForEach-Object { $_.FullName } |
        Where-Object { $path = $_; -not ($nested | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) })
}
# The servers named in a folder's rules ("servers a b").
function Get-TrustedServers($Rules) {
    $descriptions = @($Rules | ForEach-Object { $_.Description } | Sort-Object -Unique)
    if ($descriptions.Count -eq 1 -and $descriptions[0] -match '^servers ([0-9a-fA-F.: ]+)$') { return @($Matches[1].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) }
    return @()
}
# Why Windows would not apply the rules: the firewall service, a profile switched off, or a
# policy that ignores local rules. Empty when they apply.
function Get-FirewallProblems {
    $problems = @()
    $service = Get-Service -Name mpssvc -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -ne 'Running') { $problems += 'the Windows Firewall service (mpssvc) does not run' }
    foreach ($profile in @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
        if ("$($profile.Enabled)" -eq 'False') { $problems += "the firewall is off for the $($profile.Name) network profile" }
        if ("$($profile.AllowLocalFirewallRules)" -eq 'False') { $problems += "a policy ignores local rules on the $($profile.Name) profile" }
    }
    return $problems
}
# Game processes from these programs that run now.
function Get-RunningGame([string[]]$Programs) {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($Programs -contains $_.Path) })
}
function Assert-GameClosed([string[]]$Programs) {
    $running = @(Get-RunningGame $Programs)
    if ($running.Count) { throw "The game runs ($($running[0].Path)). Close it first: changing the rules now could cut it off from the server." }
}
function Test-Administrator {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}
# Runs the lines as administrator: directly when join.cmd runs as one, else through a Windows
# prompt. Returns Ok and Reason: done; declined (the prompt said no, or Windows denies it on this
# account); not-admin (it ran without administrator rights, User Account Control off on a
# standard account); failed (Detail: the error); no-start (Windows did not start it).
function Invoke-Elevated([string[]]$Lines, [bool]$Admin = (Test-Administrator)) {
    $id = [Guid]::NewGuid().ToString('N')
    $script = Join-Path $env:TEMP "roe-join-firewall-$id.ps1"
    $log = Join-Path $env:TEMP "roe-join-firewall-$id.log"
    $body = @("`$log = '$($log.Replace("'", "''"))'",
        'if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 3 }',
        'try {') + @($Lines | ForEach-Object { '    ' + $_ }) + @('} catch { Set-Content -LiteralPath $log -Value "$_"; exit 1 }', 'exit 0')
    Set-Content -LiteralPath $script -Value $body -Encoding UTF8
    $code = $null
    try {
        if ($Admin) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script | Out-Host
            $code = $LASTEXITCODE
        } else {
            $code = (Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")).ExitCode
        }
    } catch {
        $native = $_.Exception.InnerException.NativeErrorCode
        if ($null -eq $native) { $native = $_.Exception.NativeErrorCode }
        $reason = if ($native -eq 1223 -or ($null -eq $native -and $_.Exception.Message -match 'cancel')) { 'declined' } else { 'no-start' }
        return [pscustomobject]@{ Ok = $false; Reason = $reason; Detail = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue
    }
    $detail = ''
    if (Test-Path -LiteralPath $log) { $detail = "$(Get-Content -LiteralPath $log -Raw)".Trim(); Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue }
    if ($code -eq 0) { return [pscustomobject]@{ Ok = $true; Reason = 'done'; Detail = '' } }
    if ($code -eq 3) { return [pscustomobject]@{ Ok = $false; Reason = 'not-admin'; Detail = '' } }
    return [pscustomobject]@{ Ok = $false; Reason = 'failed'; Detail = $detail }
}
# What went wrong in the administrator step, in words. Empty when it worked.
function Get-ElevationNote($Result) {
    if (-not $Result -or $Result.Reason -eq 'done') { return '' }
    switch ($Result.Reason) {
        'declined' { return 'The administrator prompt was declined, or Windows does not allow it on this account.' }
        'not-admin' { return 'The step ran without administrator rights (User Account Control is off or never asks on this account, so no prompt appeared).' }
        'no-start' { return "Windows could not start the step as administrator: $($Result.Detail)" }
    }
    if ($Result.Detail) { return "Changing the firewall rules failed: $($Result.Detail)" }
    return 'Changing the firewall rules failed.'
}
# Enabled block rules of other programs (other launchers, or Windows' own "blocked some
# features" prompt) that name one of these programs. A block rule wins over any allow. Local
# ones can be removed, others (group policy, a security product) only where they come from.
function Get-ForeignBlockRules([string[]]$Programs) {
    $found = @()
    $filters = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {
        $program = [Environment]::ExpandEnvironmentVariables("$($_.Program)")
        $Programs | Where-Object { $_ -ieq $program } })
    foreach ($filter in $filters) {
        foreach ($rule in @($filter | Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
            if ("$($rule.Action)" -ne 'Block' -or "$($rule.Enabled)" -ne 'True' -or "$($rule.Group)" -like 'ROE2022-*') { continue }
            $found += [pscustomobject]@{ Name = $rule.Name; DisplayName = "$($rule.DisplayName)"; Program = [Environment]::ExpandEnvironmentVariables("$($filter.Program)")
                Direction = "$($rule.Direction)"; Local = "$($rule.PolicyStoreSourceType)" -eq 'Local' }
        }
    }
    return $found
}
# Security products other than Windows Firewall that say they run the firewall.
function Get-OtherFirewalls {
    return @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.displayName)" } | Where-Object { $_ -and $_ -notmatch 'Windows' } | Sort-Object -Unique)
}
# What still keeps the game from the servers after the firewall step: a program without its
# enabled rule for exactly the trusted servers (Own: Program, Enabled, Description; from the
# active store), a block rule of another program (Blocking). Empty when the rules are right.
# Own is $null with the rules off.
function Get-RuleProblems([string[]]$Programs, $Own, [string[]]$Wanted, $Blocking) {
    $problems = @()
    if ($null -ne $Own) {
        $want = @($Wanted | Sort-Object -Unique) -join ' '
        $missing = @(); $off = @(); $stale = @()
        foreach ($program in $Programs) {
            $rules = @($Own | Where-Object { $_ -and $_.Program -ieq $program })
            if (-not $rules.Count) { $missing += $program; continue }
            $on = @($rules | Where-Object { "$($_.Enabled)" -eq 'True' })
            if (-not $on.Count) { $off += $program; continue }
            if (-not @($on | Where-Object { (@(Get-TrustedServers @($_) | Sort-Object -Unique) -join ' ') -eq $want }).Count) { $stale += $program }
        }
        if ($missing.Count) { $problems += "no join.cmd rule for $($missing.Count) of $($Programs.Count) game programs (for example $(Split-Path -Leaf $missing[0]))" }
        if ($off.Count) { $problems += "the join.cmd rule is off for $($off.Count) game programs" }
        if ($stale.Count) { $problems += "the join.cmd rules of $($stale.Count) game programs trust other servers than $($Wanted -join ', ')" }
    }
    foreach ($rule in @($Blocking | Where-Object { $_ })) {
        $where = if ($rule.Local) { 'a local rule' } else { 'a rule of a policy or security product' }
        $leaf = if ("$($rule.Program)") { Split-Path -Leaf "$($rule.Program)" } else { 'the game' }
        $problems += "$where blocks $leaf ($($rule.Direction)): `"$($rule.DisplayName)`""
    }
    return $problems
}
# What to do about it.
function Get-FirewallAdvice([string]$Self, $Blocking, [bool]$Admin) {
    $lines = @()
    if (@($Blocking | Where-Object { $_ -and -not $_.Local }).Count) {
        $lines += 'Remove or turn off the rules of the policy or security product where they come from (or ask who manages this PC).'
    }
    if ($Admin) {
        $lines += 'join.cmd already runs as administrator: check the error above, or run "join.cmd firewall" to see the rules.'
    } else {
        $lines += 'Right-click join.cmd > Run as administrator, or in a command prompt opened with "Run as administrator":'
        $lines += "  `"$Self`""
        $lines += 'On a standard Windows account this needs an administrator''s password.'
    }
    $lines += 'Or turn the rules off with "join.cmd firewall off" (then the game can reach the internet).'
    return $lines
}
function Get-RemoveLines($Rules) {
    return @($Rules | Where-Object { $_ } | ForEach-Object { "Remove-NetFirewallRule -Name '" + $_.Name.Replace("'", "''") + "' -ErrorAction SilentlyContinue" })
}
# A folder's rules of this launcher (Own), and others that block one of its programs (Other):
# the server launcher's for this folder, ones made for another folder, or local block rules of
# other programs. Block rules win, so those would block the server too. Fixed: block rules of a
# policy or security product, which join.cmd cannot remove.
function Get-FolderRules([string]$Client, [string[]]$Programs) {
    $id = Get-FirewallGroup $Client
    $group = "ROE2022-join-$id"
    $all = @(Get-NetFirewallRule -Group 'ROE2022-*' -ErrorAction SilentlyContinue)
    $own = @($all | Where-Object { $_.Group -eq $group })
    $other = @($all | Where-Object { $_.Group -ne $group } |
        Where-Object { $_.Group -eq "ROE2022-local-$id" -or ($Programs -contains ($_ | Get-NetFirewallApplicationFilter).Program) })
    $foreign = @(Get-ForeignBlockRules $Programs)
    $other += @($foreign | Where-Object { $_.Local })
    return [pscustomobject]@{ Group = $group; Own = $own; Other = $other; Fixed = @($foreign | Where-Object { -not $_.Local }) }
}
# This folder's rules as Windows applies them (the active store), for Get-RuleProblems.
function Get-ActiveOwnRules([string]$Group) {
    return @(Get-NetFirewallRule -Group $Group -PolicyStore ActiveStore -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Enabled = "$($_.Enabled)"; Description = $_.Description
            Program = [Environment]::ExpandEnvironmentVariables("$(($_ | Get-NetFirewallApplicationFilter).Program)") } })
}
# After the firewall step: whether the rules really apply and nothing else blocks the game.
# Problems (empty when all is right) and Blocking (the block rules, for Get-FirewallAdvice).
# Wanted: the trusted servers; RulesOn false: only block rules count.
function Get-FirewallCheck([string]$Client, [string[]]$Programs, [string[]]$Wanted, [bool]$RulesOn) {
    $folder = Get-FolderRules $Client $Programs
    $own = if ($RulesOn) { @(Get-ActiveOwnRules $folder.Group) } else { $null }
    # Other: foreign block rules (with Local) and rules of play.cmd or another folder; with the
    # rules off, this folder's own ones block too.
    $left = @($folder.Other) + @(if (-not $RulesOn) { $folder.Own })
    $blocking = @($folder.Fixed) + @($left | Where-Object { $_ } | ForEach-Object {
        if ($null -ne $_.Local) { $_ }
        else { [pscustomobject]@{ DisplayName = "$($_.DisplayName)"; Program = "$(($_ | Get-NetFirewallApplicationFilter).Program)"; Direction = "$($_.Direction)"; Local = $true } } })
    return [pscustomobject]@{ Problems = @(Get-RuleProblems $Programs $own $Wanted $blocking); Blocking = $blocking }
}
# The check above; when something is wrong, says what happened and what to do and asks whether to
# start anyway (throws when not).
function Confirm-FirewallState([string]$Client, [string[]]$Programs, [string[]]$Wanted, [bool]$RulesOn, $Step) {
    $check = Get-FirewallCheck $Client $Programs $Wanted $RulesOn
    $problems = @($check.Problems)
    $blocking = $check.Blocking
    if (-not $problems.Count) { return }
    Write-Host ''
    Write-Host 'The firewall rules are not as they should be, so the game may not reach the server:' -ForegroundColor Yellow
    $note = Get-ElevationNote $Step
    if ($note) { Write-Host $note -ForegroundColor Yellow }
    foreach ($problem in @($problems | Select-Object -First 5)) { Write-Host "  - $problem" -ForegroundColor Yellow }
    if ($problems.Count -gt 5) { Write-Host "  - and $($problems.Count - 5) more (join.cmd firewall shows them)" -ForegroundColor Yellow }
    foreach ($line in (Get-FirewallAdvice $env:ROE_JOIN_SELF $blocking (Test-Administrator))) { Write-Host $line }
    if ((Ask 'Start the game anyway? (y/n)' 'n') -notmatch '^[yY]') { throw 'Cancelled: the firewall rules are not in place.' }
}
# Firewall: the setting (true on, false off, $null not asked yet).
function Show-Firewall([string]$Client, $Firewall) {
    $problems = @(Get-FirewallProblems)
    if ($problems.Count) { Write-Host ('Windows does not apply firewall rules: ' + ($problems -join '; ') + '.') -ForegroundColor Yellow }
    else { Write-Host 'Windows Firewall runs and applies local rules.' }
    $join = @(Get-NetFirewallRule -Group 'ROE2022-join-*' -ErrorAction SilentlyContinue)
    $local = @(Get-NetFirewallRule -Group 'ROE2022-local-*' -ErrorAction SilentlyContinue)
    Write-Host ("Rules of join.cmd: $($join.Count) for $(@($join | ForEach-Object { $_.Group } | Sort-Object -Unique).Count) game folders; " +
        "of the server launcher: $($local.Count).")
    if (Test-Client $Client) {
        $programs = Get-GamePrograms $Client
        $folder = Get-FolderRules $Client $programs
        $trusted = @(Get-TrustedServers $folder.Own)
        $names = if ($trusted.Count) { $trusted -join ', ' } else { 'none' }
        Write-Host "This game folder ($Client): $($folder.Own.Count) rules for $($programs.Count) programs, trusted servers: $names."
        $active = @(Get-NetFirewallRule -Group $folder.Group -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' })
        if ($folder.Own.Count -and $active.Count -lt $folder.Own.Count) { Write-Host "Only $($active.Count) of them are active." -ForegroundColor Yellow }
        if ($folder.Other.Count) { Write-Host "$($folder.Other.Count) other rules block programs of this folder; the next join removes them." }
        foreach ($rule in $folder.Fixed) { Write-Host "A rule of a policy or security product blocks $(Split-Path -Leaf $rule.Program): `"$($rule.DisplayName)`" (remove it where it comes from)." -ForegroundColor Yellow }
        foreach ($product in (Get-OtherFirewalls)) { Write-Host "$product says it runs the firewall: allow the game there too." }
        foreach ($process in (Get-RunningGame $programs)) {
            $remote = @(Get-NetTCPConnection -OwningProcess $process.Id -ErrorAction SilentlyContinue |
                Where-Object { $_.RemoteAddress -notin @('0.0.0.0', '::', '127.0.0.1', '::1') } |
                ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort) ($($_.State))" } | Sort-Object -Unique)
            $list = if ($remote.Count) { $remote -join ', ' } else { 'none' }
            Write-Host "Running: $($process.Path) (process $($process.Id)), TCP connections: $list."
        }
    }
    $state = if ($null -eq $Firewall) { 'not asked yet' } elseif ($Firewall) { 'on' } else { 'off' }
    Write-Host "join.cmd creates rules: $state. Commands: join.cmd firewall on | off | reset"
}
# The rules that let a folder's programs reach only this computer and the trusted servers. The
# new rules are created before the old ones go; if that fails, the new ones are removed again
# and the old ones stay.
function Set-FolderRules([string[]]$Programs, $Folder, [string[]]$Trusted) {
    $wanted = 'servers ' + ($Trusted -join ' ')
    $ranges = (Get-BlockedRanges $Trusted | ForEach-Object { "'" + $_ + "'" }) -join ','
    $generation = [DateTime]::UtcNow.ToString('yyMMddHHmmss')
    $lines = @('$ErrorActionPreference = ''Stop''', '$created = @()', 'try {')
    for ($index = 0; $index -lt $Programs.Count; $index++) {
        $name = "$($Folder.Group)-$generation-$index"
        $lines += ("    New-NetFirewallRule -Name '$name' -DisplayName '$name' -Group '$($Folder.Group)' -Description '$wanted' " +
            "-Direction Outbound -Action Block -Program '" + $Programs[$index].Replace("'", "''") + "' -RemoteAddress @($ranges) -Profile Any -Enabled True | Out-Null")
        $lines += "    `$created += '$name'"
    }
    $lines += @(Get-RemoveLines (@($Folder.Own) + @($Folder.Other)) | ForEach-Object { '    ' + $_ })
    $lines += @('} catch {', '    foreach ($name in $created) { Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue }', '    throw', '}')
    return Invoke-Elevated $lines
}
function Remove-Rules($Rules, [string]$What) {
    $Rules = @($Rules | Where-Object { $_ })
    if (-not $Rules.Count) { Write-Host "No firewall rules $What."; return }
    $prompt = if (Test-Administrator) { '' } else { ' (a Windows prompt appears)' }
    Write-Host "Removing $($Rules.Count) firewall rules $What$prompt."
    $step = Invoke-Elevated (@('$ErrorActionPreference = ''Continue''') + @(Get-RemoveLines $Rules))
    if (-not $step.Ok) { throw ('The firewall rules were not removed. ' + (Get-ElevationNote $step)) }
    Write-Host 'Removed.'
}

# --- Account backup -------------------------------------------------------------------------
# One JSON file with every server's accounts (names, keys, last use), certificate pin, address and
# name, the same for join.cmd and join.py: {"format": "roe-join-accounts", "version": 1,
# "servers": [{"address", "name", "pin", "accounts": [{"name", "token", "last_used"}]}]}.
$backupFormat = 'roe-join-accounts'
$backupWarning = 'The file holds your account keys: anyone who has it can play as you. Keep it private.'
# A saved server address fit for a folder name: no path, at most 255 characters.
function Test-BackupAddress([string]$Address) { return $Address -and $Address.Length -le 255 -and $Address -match '^[A-Za-z0-9._:\[\]-]+$' -and $Address -notmatch '^\.+$' }
# The backup of every server in Root (the roe-join folder) and the settings' servers.
function Get-AccountBackup([string]$Root, $Settings) {
    $rows = @()
    foreach ($s in @(Read-Servers $Settings)) {
        $folder = Join-Path $Root (Get-ServerFolderName $s.address)
        $pinPath = Join-Path $folder 'server.pin'
        $pin = if (Test-Path -LiteralPath $pinPath) { (Get-Content -LiteralPath $pinPath -Raw).Trim() } else { '' }
        $saved = Read-Accounts $folder
        $accounts = @($saved | ForEach-Object { [pscustomobject]@{ name = $_.name; token = $_.token; last_used = [int64]$_.last_used } })
        if (-not $accounts.Count -and -not $pin) { continue }
        $rows += [pscustomobject]@{ address = $s.address; name = "$($s.name)"; pin = $pin; accounts = $accounts }
    }
    return [pscustomobject]@{ format = $backupFormat; version = 1; servers = $rows }
}
function Export-Accounts([string]$Root, $Settings, [string]$File) {
    $backup = Get-AccountBackup $Root $Settings
    $json = ConvertTo-Json -Depth 6 -InputObject $backup
    [IO.File]::WriteAllText($File, $json, (New-Object Text.UTF8Encoding $false))
    $count = 0; foreach ($s in $backup.servers) { $count += @($s.accounts).Count }
    return [pscustomobject]@{ Servers = @($backup.servers).Count; Accounts = $count }
}
# Merges a backup into Root: new accounts are added, one already there (same key or name) keeps
# whichever was used last; a different certificate pin is replaced only when the player says so
# (else that server is skipped). Returns the settings' servers list with the new servers, and
# what was done.
function Import-Accounts([string]$Root, $Settings, [string]$File) {
    $backup = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json
    if ("$($backup.format)" -ne $backupFormat -or -not ($backup.version -is [int] -or $backup.version -is [long]) -or [int64]$backup.version -lt 1) {
        throw "$File is no account backup of join.cmd or join.py."
    }
    $servers = @(Read-Servers $Settings)
    $result = [pscustomobject]@{ Servers = $servers; Added = 0; Updated = 0; Skipped = @() }
    foreach ($s in @($backup.servers)) {
        $address = "$($s.address)".Trim()
        if (-not (Test-BackupAddress $address)) { continue }
        $folder = Join-Path $Root (Get-ServerFolderName $address)
        $pin = "$($s.pin)".Trim().ToLowerInvariant()
        if ($pin -and $pin -notmatch '^[0-9a-f]{64}$') { $pin = '' }
        $pinPath = Join-Path $folder 'server.pin'
        if ($pin -and (Test-Path -LiteralPath $pinPath)) {
            $mine = (Get-Content -LiteralPath $pinPath -Raw).Trim()
            if ($mine -ne $pin) {
                Write-Host "The backup has another server certificate for $address than this computer ($mine)."
                Write-Host 'Replace it only if the server was set up again; otherwise someone may be in between.'
                if ((Ask "Take the backup's certificate and accounts for $address? (y/n)" 'n') -notmatch '^[yY]') { $result.Skipped += $address; continue }
            }
        }
        $list = Read-Accounts $folder
        $changed = $false
        foreach ($a in @($s.accounts)) {
            if (-not $a -or "$($a.token)" -cnotmatch '^[0-9a-f]{64}$') { continue }
            $name = "$($a.name)"
            if (-not $name -or $name.Length -gt 24 -or $name -match '[\x00-\x1f]') { $name = '?' }
            $last = [int64]0
            try { $last = [int64]$a.last_used } catch { }
            $new = [pscustomobject]@{ name = $name; token = "$($a.token)"; last_used = $last }
            $same = @($list | Where-Object { $_.token -ceq $new.token -or ($name -ne '?' -and $_.name -eq $name) })
            if (-not $same.Count) { [void]$list.Add($new); $result.Added++; $changed = $true; continue }
            if ($same[0].last_used -lt $last) {
                $list[$list.IndexOf($same[0])] = $new; $result.Updated++; $changed = $true
            }
        }
        if ($changed) { Save-Accounts $folder $list | Out-Null }
        if ($pin) { New-Item -ItemType Directory -Force -Path $folder | Out-Null; Set-Content -LiteralPath $pinPath -Value $pin -Encoding ASCII }
        $key = Get-ServerFolderName $address
        $entry = @($result.Servers | Where-Object { (Get-ServerFolderName $_.address) -eq $key })
        $name = Get-CleanServerName "$($s.name)"
        if (-not $entry.Count) {
            $used = [int64]0; foreach ($a in $list) { if ($a.last_used -gt $used) { $used = $a.last_used } }
            $result.Servers = @($result.Servers) + @([pscustomobject]@{ address = $address; last_used = $used; name = $name; addresses = [string[]]@(); ips = [string[]]@() })
        } elseif ($name -and -not "$($entry[0].name)") {
            $entry[0] | Add-Member -NotePropertyName name -NotePropertyValue $name -Force
        }
    }
    return $result
}

# --- Voice chat -----------------------------------------------------------------------------
$voiceFile = 'GCloudVoice.dll'
$voiceBackupName = 'roe-join-backup'  # in the game folder: the original DLL
$joinFolder = Split-Path -Parent "$env:ROE_JOIN_SELF"
$voiceSource = Join-Path $joinFolder 'voice'
# Where our DLL is looked for without asking: next to join.cmd, then in its voice folder.
function Get-DefaultVoiceDll {
    foreach ($folder in @(@($joinFolder, $voiceSource) | Where-Object { $_ })) {
        $candidate = Join-Path $folder $voiceFile
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return Join-Path $(if ($joinFolder) { $joinFolder } else { $voiceSource }) $voiceFile
}
$voiceDownload = 'https://github.com/mschnati/roe-os-client/raw/main/voice/GCloudVoice.dll'
$voiceBackups = Join-Path (Join-Path $env:APPDATA 'roe-join') 'voice-backup'
$verifyHint = 'Steam: Ring of Elysium > Properties > Installed Files > Verify integrity of game files'
function Get-VoiceBackupFolder([string]$Client) { return Join-Path $voiceBackups (Get-FirewallGroup $Client) }
# The original DLL is kept in the game folder (roe-join-backup\GCloudVoice.dll), where players find
# it; the record with the hashes stays in %APPDATA%.
function Get-VoiceOriginal([string]$Client) { return Join-Path (Join-Path $Client $voiceBackupName) $voiceFile }
function Write-VoiceReadme([string]$Client) {
    $text = "The game's original $voiceFile, saved by join.cmd before it put in the one for voice chat.`r`n" +
        "join.cmd puts it back when the game exits. To do it by hand: copy $voiceFile from this folder into`r`n$Client`r`n" +
        "(replace the file there). Or in Steam: Ring of Elysium > Properties > Installed Files > Verify integrity of game files.`r`n"
    try { Set-Content -LiteralPath (Join-Path (Join-Path $Client $voiceBackupName) 'README.txt') -Value $text -Encoding ASCII -NoNewline } catch { }
}
function Test-GameRunning([string]$Client) {
    $exe = Join-Path $Client 'Europa_Client.exe'
    return [bool]@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }).Count
}
# Copies Source over Target through a temporary file: '' when Target then has the hash, else why not.
function Copy-Checked([string]$Source, [string]$Target, [string]$Hash) {
    $temp = $Target + '.roe-join'
    try {
        [IO.File]::Copy($Source, $temp, $true)
        if ((Get-Sha256 $temp) -ne $Hash) { throw 'the copy differs' }
        if (Test-Path -LiteralPath $Target) { [IO.File]::Replace($temp, $Target, [NullString]::Value) } else { [IO.File]::Move($temp, $Target) }
        return ''
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        return $_.Exception.Message
    }
}
function Read-VoiceRecord([string]$Folder) {
    try { return Get-Content -LiteralPath (Join-Path $Folder 'backup.json') -Raw | ConvertFrom-Json } catch { return $null }
}
# Puts the original DLL back where ours is in place. False when it could not.
function Restore-Voice([string]$Client, [int]$Wait = 0) {
    $folder = Get-VoiceBackupFolder $Client
    $record = Read-VoiceRecord $folder
    if (-not $record) { return $true }
    $target = Join-Path $Client $voiceFile
    # No DLL at all (deleted by hand): the game cannot start without one, so the original goes back.
    $missing = -not (Test-Path -LiteralPath $target -PathType Leaf)
    if ($missing) { $current = $record.installed } else { try { $current = Get-Sha256 $target } catch {
        Write-Host "Voice chat: cannot read $target ($($_.Exception.Message)). Close the game and start join.cmd again, or: $verifyHint." -ForegroundColor Yellow
        return $false
    } }
    if ($current -ne $record.installed) { return $true }  # the original is back, or Steam replaced the file
    $deadline = (Get-Date).AddSeconds($Wait)
    while (Test-GameRunning $Client) {
        if ((Get-Date) -ge $deadline) {
            Write-Host "Voice chat: the game in $Client runs; its original $voiceFile is put back at the next start."
            return $false
        }
        Start-Sleep -Seconds 1
    }
    $saved = Get-VoiceOriginal $Client
    $good = $false
    try { $good = (Get-Sha256 $saved) -eq $record.original } catch { }
    if (-not $good) {
        Write-Host "Voice chat: the backup of the original $voiceFile ($saved) is missing or damaged, so $target is still ours. To get the original back: $verifyHint." -ForegroundColor Yellow
        return $false
    }
    $problem = ''
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $problem = Copy-Checked $saved $target $record.original
        if (-not $problem) { Write-Host "Voice chat: the original $voiceFile is back in $Client."; return $true }
        Start-Sleep -Seconds 1
    }
    Write-Host "Voice chat: could not put the original $voiceFile back in $Client ($problem). Close the game and start join.cmd again (it puts it back first), or: $verifyHint." -ForegroundColor Yellow
    return $false
}
# At every start: the original back wherever ours was left (a crash or a closed window).
function Restore-AllVoice {
    foreach ($file in @(Get-ChildItem -LiteralPath $voiceBackups -Filter 'backup.json' -Recurse -File -ErrorAction SilentlyContinue)) {
        $record = Read-VoiceRecord $file.DirectoryName
        if ($record -and $record.folder) { Restore-Voice $record.folder | Out-Null }
    }
}
# A 64-bit (x64) Windows DLL: MZ, PE, machine 0x8664, the DLL flag.
function Test-Dll64([byte[]]$Bytes) {
    if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { return $false }
    $pe = [BitConverter]::ToInt32($Bytes, 0x3c)
    if ($pe -lt 0 -or $pe + 24 -gt $Bytes.Length) { return $false }
    return [BitConverter]::ToUInt32($Bytes, $pe) -eq 0x4550 -and [BitConverter]::ToUInt16($Bytes, $pe + 4) -eq 0x8664 -and ([BitConverter]::ToUInt16($Bytes, $pe + 22) -band 0x2000) -ne 0
}
# Why Dll cannot be our voice DLL for Client, '' when it can. Without Client: only the file itself.
function Get-VoiceDllProblem([string]$Dll, [string]$Client) {
    if (-not $Dll -or -not (Test-Path -LiteralPath $Dll -PathType Leaf)) { return "$Dll is not found" }
    if (Test-Client (Split-Path -Parent $Dll)) { return "$Dll is in a game folder; use ours from the server package" }
    try { $bytes = [IO.File]::ReadAllBytes($Dll) } catch { return "cannot read $Dll ($($_.Exception.Message))" }
    if (-not (Test-Dll64 $bytes)) { return "$Dll is not a 64-bit Windows DLL" }
    if (-not [Text.Encoding]::ASCII.GetString($bytes).Contains('GetVoiceEngine')) { return "$Dll has no GetVoiceEngine, so it is no $voiceFile" }
    if (-not $Client) { return '' }
    $hash = Get-Sha256 $Dll
    $original = "$Dll is the game's original $voiceFile, not ours"
    $record = Read-VoiceRecord (Get-VoiceBackupFolder $Client)
    if ($record -and $hash -eq $record.original) { return $original }
    # The game's own file, unless we put it there.
    $current = $null
    try { $current = Get-Sha256 (Join-Path $Client $voiceFile) } catch { }
    if ($hash -eq $current -and -not ($record -and $hash -eq $record.installed)) { return $original }
    return ''
}
# An answer to the DLL question as a full path: a folder means its GCloudVoice.dll.
function Resolve-VoiceDll([string]$Answer) {
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Answer.Trim().Trim('"').Trim("'"))
    if (Test-Path -LiteralPath $path -PathType Container) { $path = Join-Path $path $voiceFile }
    return $path
}
# Our DLL and its hash, asking for its folder where needed: @{ Dll (its full path once found);
# Asked (Dll was answered); Hash ($null: no voice this time) }.
function Select-VoiceDll([string]$Dll, [string]$Client, [bool]$AskPath) {
    # The saved DLL, or when it is gone (or none is saved) the one next to join.cmd.
    if (-not $Dll -or -not (Test-Path -LiteralPath $Dll -PathType Leaf)) { $Dll = Get-DefaultVoiceDll }
    $result = @{ Dll = $Dll; Asked = $false; Hash = $null }
    $offer = ''
    if ($AskPath) {
        if (Test-Path -LiteralPath $Dll -PathType Leaf) { $offer = $Dll }
    } else {
        $problem = Get-VoiceDllProblem $Dll $Client
        if ($problem) {
            if (-not (Test-Path -LiteralPath $Dll -PathType Leaf)) { Write-Host "Voice chat: our $voiceFile is not at $Dll." -ForegroundColor Yellow }
            else { Write-Host "Voice chat: $problem." -ForegroundColor Yellow }
            $AskPath = $true
        }
    }
    if ($AskPath) { Write-Host "Our $voiceFile is a separate download: $voiceDownload (or the voice folder of the server package)." }
    while ($AskPath) {
        $answer = Ask "Folder with our $voiceFile (or the file itself; Enter: no voice this time)" $offer
        if (-not $answer) { Write-Host 'Voice chat: no DLL chosen, so none is used this time.'; return $result }
        $path = Resolve-VoiceDll $answer
        $problem = Get-VoiceDllProblem $path $Client
        if (-not $problem) { $result.Dll = $path; $result.Asked = $true; break }
        Write-Host "Voice chat: $problem." -ForegroundColor Yellow
        $offer = ''
    }
    $result.Dll = [IO.Path]::GetFullPath($result.Dll)
    $result.Hash = Get-Sha256 $result.Dll
    return $result
}
# --- Voice chat prompt (begin) ---
# Voice chat for this start: @{ Voice (to save: $true, $false, or $null to ask again next start);
# Dll (to save as voice_dll); Pick (Select-VoiceDll's answer, $null: no voice) }. On by default:
# asked once (Enter: yes). A yes with a DLL found (saved, then used without asking) and a no are
# kept; a yes without a DLL asks again next start. Option: join.cmd voice on|off ('on' asks for
# the DLL again).
function Get-VoiceChoice($Voice, [string]$Dll, [string]$Client, [string]$Option) {
    $asked = $false
    if ($Option) { $Voice = $Option -eq 'on' }
    elseif ($null -eq $Voice) {
        Write-Host ''
        Write-Host "Voice chat needs our $voiceFile in the game folder while the game runs (the original is put back afterwards)."
        $Voice = (Ask 'Use voice chat? (y/n)' 'y') -match '^[yY]'
        $asked = $true
        Write-Host 'Change it later with: join.cmd voice on | off'
    }
    if (-not $Voice) { return @{ Voice = $false; Dll = $Dll; Pick = $null } }
    $pick = Select-VoiceDll $Dll $Client ($Option -eq 'on')
    if (-not $pick.Hash) {
        $again = if ($asked) { $null } else { $true }
        return @{ Voice = $again; Dll = $Dll; Pick = $null }
    }
    return @{ Voice = $true; Dll = $pick.Dll; Pick = $pick }
}
# --- Voice chat prompt (end) ---
# Backs up the game's DLL and puts ours (Ours; Expected: its hash when it was chosen, so a file
# changed since is not used) in. True when ours is in place.
function Install-Voice([string]$Client, [string]$Ours, [string]$Expected) {
    $actual = $null
    try { $actual = Get-Sha256 $Ours } catch { }
    if (-not $Expected) { $Expected = $actual }
    if (-not $Expected -or $actual -ne $Expected) {
        Write-Host "Voice chat: $Ours is missing or changed since it was chosen, so it is not used. Starting without voice chat." -ForegroundColor Yellow
        return $false
    }
    $problem = Get-VoiceDllProblem $Ours $Client
    if ($problem) { Write-Host "Voice chat: $problem; starting without voice chat." -ForegroundColor Yellow; return $false }
    $target = Join-Path $Client $voiceFile
    if (Test-GameRunning $Client) { Write-Host "Voice chat: the game in $Client runs already; its $voiceFile stays as it is."; return $false }
    $folder = Get-VoiceBackupFolder $Client
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        # The game's DLL is gone: ours goes in. A good backup of the original stays and comes back
        # when the game exits; without one ours stays (the game cannot start without a GCloudVoice.dll).
        $record = Read-VoiceRecord $folder
        $good = $false
        try { $good = $record -and (Get-Sha256 (Get-VoiceOriginal $Client)) -eq $record.original } catch { }
        if ($good -and $record.installed -ne $expected) {
            try {
                $temp = Join-Path $folder 'backup.json.tmp'
                [pscustomobject]@{ folder = $Client; original = $record.original; installed = $expected } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
                Move-Item -LiteralPath $temp -Destination (Join-Path $folder 'backup.json') -Force
            } catch { $good = $false }
        }
        $problem = Copy-Checked $ours $target $expected
        if ($problem) { Write-Host "Voice chat: could not put our $voiceFile into $Client ($problem); starting without voice chat." -ForegroundColor Yellow; return $false }
        if ($good) { Write-Host "Voice chat: on ($voiceFile was missing in $Client). The original is saved in $(Split-Path (Get-VoiceOriginal $Client)) and put back when the game exits." }
        else { Write-Host "Voice chat: on ($voiceFile was missing in $Client and there is no backup of the original, so ours stays there. To get the original: $verifyHint)." -ForegroundColor Yellow }
        return $true
    }
    $current = Get-Sha256 $target
    if ($current -eq $expected) {
        # Ours is never backed up, so a second start keeps the original's backup.
        $record = Read-VoiceRecord $folder
        $good = $false
        try { $good = $record -and $record.installed -eq $expected -and (Get-Sha256 (Get-VoiceOriginal $Client)) -eq $record.original } catch { }
        if (-not $good) { Write-Host "Voice chat: our $voiceFile is in $Client already, but there is no good backup of the original. To get the original back later: $verifyHint." -ForegroundColor Yellow }
        return $true
    }
    $problem = ''
    try { New-Item -ItemType Directory -Force -Path $folder | Out-Null } catch { $problem = $_.Exception.Message }
    $original = Join-Path (Join-Path $Client $voiceBackupName) $voiceFile
    if (-not $problem) { try { New-Item -ItemType Directory -Force -Path (Split-Path $original) | Out-Null } catch { $problem = $_.Exception.Message } }
    if (-not $problem) { $problem = Copy-Checked $target $original $current }
    if (-not $problem) { Write-VoiceReadme $Client }
    if (-not $problem) {
        try {
            $temp = Join-Path $folder 'backup.json.tmp'
            [pscustomobject]@{ folder = $Client; original = $current; installed = $expected } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
            Move-Item -LiteralPath $temp -Destination (Join-Path $folder 'backup.json') -Force
        } catch { $problem = $_.Exception.Message }
    }
    if ($problem) { Write-Host "Voice chat: could not back up $target ($problem); starting without voice chat." -ForegroundColor Yellow; return $false }
    $problem = Copy-Checked $ours $target $expected
    if ($problem) { Write-Host "Voice chat: could not put our $voiceFile into $Client ($problem); starting without voice chat." -ForegroundColor Yellow; return $false }
    Write-Host "Voice chat: on. The game's original $voiceFile is saved in $(Split-Path $original) and put back when the game exits (to do it by hand: copy it from there into $Client)."
    return $true
}

# One request to the account service (TLS). Nothing when the service does not answer (a server
# without accounts). Refuses a server whose certificate differs from the one seen first.
function Invoke-Account([string]$Ip, [string]$Folder, [string]$Line) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $pending = $tcp.BeginConnect($Ip, $accountPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(5000) -or -not $tcp.Connected) { return $null }
        $tcp.EndConnect($pending)
        $seen = @{}
        $check = { param($sender, $certificate, $chain, $errors)
            $seen['pin'] = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($certificate.GetRawCertData())) -replace '-', '').ToLowerInvariant()
            return $true }.GetNewClosure()
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, [Net.Security.RemoteCertificateValidationCallback]$check)
        $ssl.ReadTimeout = 5000
        $ssl.WriteTimeout = 5000
        $ssl.AuthenticateAsClient('roe_server', $null, [Security.Authentication.SslProtocols]::Tls12, $false)
        $pinPath = Join-Path $Folder 'server.pin'
        if (Test-Path -LiteralPath $pinPath) {
            if ((Get-Content -LiteralPath $pinPath -Raw).Trim() -ne $seen['pin']) {
                throw ("The server's certificate is not the one seen on the first join. Someone may be in between, or the server " +
                    "was set up again. If the server admin confirms a new certificate, delete $pinPath and start again.")
            }
        } else {
            New-Item -ItemType Directory -Force -Path $Folder | Out-Null
            Set-Content -LiteralPath $pinPath -Value $seen['pin'] -Encoding ASCII
            Write-Host ('First contact; remembered the server certificate ' + $seen['pin'])
        }
        $request = [Text.Encoding]::UTF8.GetBytes("$Line`n")
        $ssl.Write($request, 0, $request.Length)
        $ssl.Flush()
        return (New-Object IO.StreamReader($ssl, [Text.Encoding]::UTF8)).ReadLine()
    } finally {
        $tcp.Close()
    }
}
# STATS at most every 10 s per server (the server allows more; this keeps its load low): a newer
# call within 10 s gets the answer of the last one.
$script:statsCache = @{}
function Get-ServerStats([string]$Ip, [string]$Folder) {
    $now = [DateTime]::UtcNow
    if ($null -eq $script:statsCache) { $script:statsCache = @{} }
    $last = $script:statsCache[$Ip]
    if ($last -and ($now - $last.At).TotalSeconds -lt 10) { return $last.Reply }
    $reply = Invoke-Account $Ip $Folder 'STATS'
    $script:statsCache[$Ip] = @{ At = $now; Reply = $reply }
    return $reply
}
# The answer to STATS as one line, a part per region: "EU (normal): 12 online, 3 searching,
# 2 matches | AS (duel): ...". Empty from an older server.
function Format-Stats([string]$Reply) {
    if ($Reply -cne 'OK' -and $Reply -cnotmatch '^OK ') { return '' }
    $parts = @()
    foreach ($word in @($Reply.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | Select-Object -Skip 1)) {
        $fields = $word.Split(',')
        if ($fields.Count -lt 6 -or $fields[0] -notmatch '^\d+$' -or $fields[1] -cnotmatch '^[a-z]{1,12}$' -or @($fields[2..4] | Where-Object { $_ -notmatch '^\d{1,9}$' }).Count) { continue }
        $name = ''
        try { $name = [Uri]::UnescapeDataString($fields[5]) } catch { }
        $name = (($name.ToCharArray() | Where-Object { -not [char]::IsControl($_) }) -join '')
        if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
        $name = ($name -replace '\s+SERVER$', '').Trim()
        if (-not $name) { $name = "zone $($fields[0])" }
        $matchWord = if ([int]$fields[4] -eq 1) { 'match' } else { 'matches' }
        $parts += "$name ($($fields[1])): $([int]$fields[2]) online, $([int]$fields[3]) searching, $([int]$fields[4]) $matchWord"
    }
    return $parts -join ' | '
}
# The answer to INFO: what runs on the server now (counts only, no names).
function Format-ServerInfo([string]$Reply) {
    $values = @{}
    $queues = @()
    foreach ($pair in ($Reply.Substring(3) -split ' ')) {
        if ($pair -match '^queue\.([^=]+)=(\d+),(\d+)$') { $queues += "$($Matches[1]) $($Matches[2]) for up to $($Matches[3]) s" }
        elseif ($pair -match '^([a-z_]+)=(\d+)$') { $values[$Matches[1]] = [int]$Matches[2] }
    }
    $players = [int]$values['players']; $matches = [int]$values['matches']
    $text = "On the server now: $players player$(if ($players -ne 1) { 's' }) online, $matches match$(if ($matches -ne 1) { 'es' }) running, $([int]$values['waiting']) searching"
    if ($queues.Count) { $text += ' (' + ($queues -join ', ') + ')' }
    $text += '.'
    if ($values['restarting']) { $text += ' It restarts for an update soon; new searches are refused until then.' }
    return $text
}
function Ask-Name([string]$Default) {
    while ($true) {
        $answer = Ask 'Your name (1 to 24 characters)' $Default
        if ($answer -and $answer.Length -le 24 -and $answer -notmatch '[\x00-\x1f]') { return $answer }
        Write-Host 'That name is empty, too long or has control characters.'
        $Default = ''
    }
}

# The account menu: one key moves the selection (wraps around) or chooses it (Enter).
function Step-Menu([int]$Index, [string]$Key, [int]$Count) {
    switch ($Key) {
        'Enter' { return @($Index, $true) }
        'UpArrow' { return @((($Index - 1 + $Count) % $Count), $false) }
        'DownArrow' { return @((($Index + 1) % $Count), $false) }
        'Home' { return @(0, $false) }
        'End' { return @(($Count - 1), $false) }
    }
    return @($Index, $false)
}
function Show-Menu([string[]]$Entries, [int]$Index, [bool]$First) {
    if (-not $First) { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $Entries.Count)) }
    $width = ($Entries | Measure-Object -Property Length -Maximum).Maximum + 2
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        if ($i -eq $Index) { Write-Host ('> ' + $Entries[$i]).PadRight($width) -ForegroundColor Black -BackgroundColor Gray }
        else { Write-Host ('  ' + $Entries[$i]).PadRight($width) }
    }
}
function Select-MenuWithKeys([string[]]$Entries, [scriptblock]$ReadKey, [scriptblock]$Draw, [int]$Index = 0) {
    $first = $true
    while ($true) {
        & $Draw $Entries $Index $first
        $first = $false
        $step = Step-Menu $Index (& $ReadKey) $Entries.Count
        $Index = $step[0]
        if ($step[1]) { return $Index }
    }
}
# Without a key reader (redirected input): a numbered list and a typed number.
function Select-Numbered([string[]]$Entries) {
    for ($i = 0; $i -lt $Entries.Count; $i++) { Write-Host "  $($i + 1). $($Entries[$i])" }
    while ($true) {
        $answer = Ask 'Number' '1'
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Entries.Count) { return [int]$answer - 1 }
        Write-Host "Enter a number from 1 to $($Entries.Count)."
    }
}
function Select-Menu([string[]]$Entries) {
    $keys = $false
    try { $keys = -not [Console]::IsInputRedirected -and $Host.Name -eq 'ConsoleHost' } catch { }
    if ($keys) {
        Write-Host '(arrow keys, then Enter)'
        try { [Console]::CursorVisible = $false } catch { }
        try {
            return Select-MenuWithKeys $Entries { [Console]::ReadKey($true).Key.ToString() } { param($e, $i, $f) Show-Menu $e $i $f }
        } catch [InvalidOperationException], [IO.IOException] {
        } finally {
            try { [Console]::CursorVisible = $true } catch { }
        }
    }
    return Select-Numbered $Entries
}

# Options before a command: -Server <address> and -Name <name> (a name with spaces in quotes, or
# last). Returns @{ Server; Name; Command (the rest) }.
function Read-Arguments([string]$Text) {
    $result = @{ Server = ''; Name = ''; Command = $Text.Trim() }
    while ($result.Command -match '^-(Server|Name)\s+("([^"]*)"|(\S+))\s*(.*)$') {
        $value = if ($Matches[3] -or $Matches[2] -eq '""') { $Matches[3] } else { $Matches[4] }
        $option = $Matches[1]
        $rest = $Matches[5]
        if ($option -eq 'Name' -and $rest -and $rest -notmatch '^-Server\s') { $value = "$value $rest"; $rest = '' }  # -Name Anna Lee
        $result[$option] = $value.Trim()
        $result.Command = $rest.Trim()
    }
    return $result
}

# Servers joined before (the settings' "servers"), the most recently used first:
# @{ address; last_used; name; addresses; ips }.
function Get-ServerFolderName([string]$Address) { return $Address.ToLowerInvariant() -replace '[^a-z0-9._-]', '_' }
function Read-Servers($Settings) {
    $found = [ordered]@{}
    foreach ($s in @($Settings.servers)) {
        if (-not $s -or -not "$($s.address)".Trim()) { continue }
        $key = Get-ServerFolderName "$($s.address)".Trim()
        $last = [int64]0
        try { $last = [int64]$s.last_used } catch { }
        if (-not $found.Contains($key)) {
            $found[$key] = [pscustomobject]@{ address = "$($s.address)".Trim(); last_used = $last; name = (Get-CleanServerName "$($s.name)")
                addresses = (Get-CleanAddresses $s.addresses); ips = (Get-CleanAddresses $s.ips) }
        }
    }
    return @($found.Values | Sort-Object -Property last_used -Descending)
}
# The list with Address used now, on top (its saved name kept).
function Add-ServerUse($Servers, [string]$Address, [int64]$Now = 0) {
    if (-not $Now) { $Now = Get-UnixTime }
    $key = Get-ServerFolderName $Address
    $old = @($Servers | Where-Object { $_ -and (Get-ServerFolderName $_.address) -eq $key })
    $name = if ($old.Count) { "$($old[0].name)" } else { '' }
    $addresses = [string[]]@(); $ips = [string[]]@()
    if ($old.Count) { $addresses = Get-CleanAddresses $old[0].addresses; $ips = Get-CleanAddresses $old[0].ips }
    $entry = [pscustomobject]@{ address = $Address; last_used = $Now; name = $name; addresses = $addresses; ips = $ips }
    return @(@($entry) + @($Servers | Where-Object { $_ -and (Get-ServerFolderName $_.address) -ne $key }))
}
# A saved address list as canonical addresses (anything else dropped).
function Get-CleanAddresses($List) {
    return ,[string[]]@(@($List) | ForEach-Object { ConvertTo-CanonicalAddress "$_" } | Where-Object { $_ } | Sort-Object -Unique)
}
# The saved lists of Address: what it lists (Listed) and its own addresses (Ips); $null keeps one.
function Set-ServerAddresses($Servers, [string]$Address, $Listed, $Ips) {
    $key = Get-ServerFolderName $Address
    foreach ($s in @($Servers | Where-Object { $_ -and (Get-ServerFolderName $_.address) -eq $key })) {
        if ($null -ne $Listed) { $s | Add-Member -NotePropertyName addresses -NotePropertyValue (Get-CleanAddresses $Listed) -Force }
        if ($null -ne $Ips) { $s | Add-Member -NotePropertyName ips -NotePropertyValue (Get-CleanAddresses $Ips) -Force }
    }
}
# A server name fit to show: no control characters, at most 40 characters.
function Get-CleanServerName([string]$Text) {
    $text = $Text -replace '[\p{C}\p{Zl}\p{Zp}]', ''
    if ($text.Length -gt 40) { $text = $text.Substring(0, 40); if ([char]::IsHighSurrogate($text[39])) { $text = $text.Substring(0, 39) } }
    return $text.Trim()
}
# A dotted version ("0.9") as four numbers; $null when it is no version.
function ConvertTo-VersionKey([string]$Version) {
    if ($Version -notmatch '^\d{1,6}(\.\d{1,6}){0,3}$') { return $null }
    $parts = @($Version.Split('.') | ForEach-Object { [int]$_ }) + @(0, 0, 0)
    return ,[int[]]$parts[0..3]
}
# -1, 0 or 1 as version A is older, the same or newer than B.
function Compare-Version([string]$A, [string]$B) {
    $x = ConvertTo-VersionKey $A; $y = ConvertTo-VersionKey $B
    for ($i = 0; $i -lt 4; $i++) { if ($x[$i] -ne $y[$i]) { if ($x[$i] -lt $y[$i]) { return -1 }; return 1 } }
    return 0
}
# The VERSION answer: min, current (as text, '0' when missing) and url; $null without an OK.
function Get-ScriptVersions([string]$Reply) {
    if (-not $Reply.StartsWith('OK ', [StringComparison]::Ordinal)) { return $null }
    $values = @{}
    foreach ($pair in ($Reply.Substring(3) -split ' ')) { if ($pair -match '^([a-z_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    $found = @{ min = '0'; current = '0'; url = $joinUrl }
    foreach ($key in 'min', 'current') { if (ConvertTo-VersionKey "$($values[$key])") { $found[$key] = "$($values[$key])" } }
    $url = ''
    try { $url = [Uri]::UnescapeDataString("$($values['url'])") -replace '[\p{C}\s]', '' } catch { }
    if ($url.Length -gt 200) { $url = $url.Substring(0, 200) }
    if ($url -match '^https?://.') { $found.url = $url }
    return $found
}
# Throws when this script is older than the server needs; a line when a newer one exists, else $null.
# Script: the name the lines give this script.
function Get-VersionNotice([string]$Reply, [string]$Have = $joinVersion, [string]$Script = 'join.cmd') {
    $versions = Get-ScriptVersions $Reply
    if (-not $versions) { return $null }
    if ((Compare-Version $Have $versions.min) -lt 0) {
        throw ("This $Script is version $Have; the server needs version $($versions.min) or newer. " +
            "Download the new $Script from $($versions.url) and start it again.")
    }
    if ((Compare-Version $Have $versions.current) -lt 0) { return "A newer $Script (version $($versions.current)) is at $($versions.url); this one (version $Have) still works." }
    return $null
}
# The server name in an INFO answer, '' for none.
function Get-InfoServerName([string]$Reply) {
    if ($Reply -notmatch '(^| )name=(\S*)$') { return '' }
    return Get-CleanServerName ([Uri]::UnescapeDataString($Matches[2]))
}
# The saved name of Address set to Name ('' removes it); true when it changed.
function Set-ServerName($Servers, [string]$Address, [string]$Name) {
    $key = Get-ServerFolderName $Address
    foreach ($s in @($Servers | Where-Object { $_ -and (Get-ServerFolderName $_.address) -eq $key })) {
        if ("$($s.name)" -cne $Name) { $s | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force; return $true }
    }
    return $false
}
function Get-ServerLabel($Entry) { if ("$($Entry.name)") { return "$($Entry.name) ($($Entry.address))" }; return $Entry.address }
# The server address: Given (-Server), else the menu of saved servers; the first start asks.
function Select-Server($Servers, [string]$Given) {
    if ($Given) { return $Given }
    $question = 'Server address (IP or domain)'
    $Servers = @($Servers | Where-Object { $_ })
    if (-not $Servers.Count) { return Ask $question '' }
    Write-Host 'Server:'
    $index = Select-Menu (@($Servers | ForEach-Object { Get-ServerLabel $_ }) + @('Enter another server (IP or domain)'))
    if ($index -lt $Servers.Count) { return $Servers[$index].address }
    return Ask $question ''
}

# Saved accounts of a server (accounts.json in its folder): name, key and last use (unix
# seconds), the most recently used first.
function Read-Accounts([string]$Folder) {
    $list = @()
    $path = Join-Path $Folder 'accounts.json'
    if (Test-Path -LiteralPath $path) {
        try {
            foreach ($a in @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).accounts)) {
                # No key: a name for a server without an account service (play.cmd's own server).
                if (-not $a -or ("$($a.token)" -cnotmatch '^[0-9a-f]{64}$' -and ("$($a.token)" -or -not $a.name))) { continue }
                $name = if ($a.name) { "$($a.name)" } else { '?' }
                $list += [pscustomobject]@{ name = $name; token = "$($a.token)"; last_used = [int64]$a.last_used }
            }
        } catch { }
    }
    $sorted = New-Object System.Collections.ArrayList
    foreach ($a in @($list | Sort-Object -Property last_used -Descending)) { [void]$sorted.Add($a) }
    return ,$sorted
}
function Save-Accounts([string]$Folder, $Accounts) {
    New-Item -ItemType Directory -Force -Path $Folder | Out-Null
    $path = Join-Path $Folder 'accounts.json'
    $rows = @($Accounts | ForEach-Object { [pscustomobject]@{ name = $_.name; token = $_.token; last_used = $_.last_used } })
    $json = ConvertTo-Json -Depth 4 -InputObject ([pscustomobject]@{ accounts = $rows })
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
    return $path
}
function Get-UnixTime { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
# The saved account to log in with, or nothing for a new one. -Name picks without the menu.
function Select-Account($Accounts, [string]$Name) {
    if ($Name) {
        foreach ($a in $Accounts) { if ($a.name -eq $Name) { return $a } }  # case ignored
        return $null
    }
    if (-not $Accounts.Count) { return $null }
    Write-Host 'Account:'
    $index = Select-Menu (@($Accounts | ForEach-Object { $_.name }) + @('Create a new account'))
    if ($index -lt $Accounts.Count) { return $Accounts[$index] }
    return $null
}
# The current names from the server (renamed in the game); true when one changed.
function Update-AccountNames([string]$Ip, [string]$Folder, $Accounts) {
    $changed = $false
    foreach ($a in @($Accounts | Where-Object { $_.token })) {
        $reply = Invoke-Account $Ip $Folder "NAME $($a.token)"
        if ($null -eq $reply -or ($reply -notlike 'OK *' -and $reply -ne 'DENIED')) { break }  # no answer or the limit
        if ($reply -like 'OK ?*' -and $reply.Substring(3) -cne $a.name) { $a.name = $reply.Substring(3); $changed = $true }
    }
    return $changed
}
function Stop-Refused([string]$Reply, [string]$Name) {
    if ($Reply -eq 'LIMIT') { throw 'Too many attempts from this address. Try again in a few minutes.' }
    if ($Reply -eq 'BANNED') {
        $who = if ($Name) { "The name $Name or your address" } else { 'Your address' }
        throw "$who is banned on this server. Ask the server admin if you think this is a mistake."
    }
    throw "The account service answered: $Reply"
}
# A new account, saved; nothing when the server has no account service. Without a name the
# server names it (first-login on: the game asks for the real one); else the player picks it.
function New-Account([string]$Ip, [string]$Folder, $Accounts, [string]$Name) {
    if (-not $Name) {
        $reply = Invoke-Account $Ip $Folder 'NEW'
        if ($null -eq $reply) { return $null }
        if ($reply -cmatch '^OK ([0-9a-f]{64}) (.+)$') {
            $entry = [pscustomobject]@{ name = $Matches[2]; token = $Matches[1]; last_used = (Get-UnixTime) }
            $Accounts.Insert(0, $entry)
            $path = Save-Accounts $Folder $Accounts
            Write-Host "New account created; you choose its name in the game. Its key is saved in $path"
            return $entry
        }
        if ($reply -ne 'NAME-REQUIRED') { Stop-Refused $reply '' }
        $Name = Ask-Name ''
    }
    while ($true) {
        $reply = Invoke-Account $Ip $Folder "CLAIM $Name"
        if ($null -eq $reply) { return $null }
        if ($reply -cmatch '^OK ([0-9a-f]{64})$') {
            $entry = [pscustomobject]@{ name = $Name; token = $Matches[1]; last_used = (Get-UnixTime) }
            $Accounts.Insert(0, $entry)
            $path = Save-Accounts $Folder $Accounts
            Write-Host "The name $Name is yours on this server. Its key is saved in $path"
            return $entry
        }
        if ($reply -ne 'TAKEN' -and $reply -ne 'INVALID') { Stop-Refused $reply $Name }
        Write-Host "The name $Name is taken on this server or not allowed. Choose another one."
        $Name = Ask-Name ''
    }
}
# A server without an account service takes a plain name: kept in accounts.json without a key,
# so the menu offers it next time.
function Save-PlainName([string]$Folder, $Accounts, [string]$Name) {
    $entry = $null
    foreach ($a in $Accounts) { if (-not $a.token -and $a.name -eq $Name) { $entry = $a } }
    if (-not $entry) { $entry = [pscustomobject]@{ name = $Name; token = ''; last_used = 0 }; $Accounts.Insert(0, $entry) }
    $entry.last_used = Get-UnixTime
    $sorted = @($Accounts | Sort-Object -Property last_used -Descending)
    $Accounts.Clear()
    foreach ($a in $sorted) { [void]$Accounts.Add($a) }
    Save-Accounts $Folder $Accounts | Out-Null
    return [pscustomobject]@{ Uid = $null; Name = $Name }
}
# Logs in: Uid is the one-time ticket the game passes on as its -uid (nothing: the server has
# no account service), Name the account's current name.
function Invoke-Login([string]$Ip, [string]$Folder, $Accounts, $Entry, [string]$Name) {
    if ($Entry -and -not $Entry.token) {
        # A saved name without a key: an account under that name once the server has a service.
        $named = $Entry
        $Entry = New-Account $Ip $Folder $Accounts $named.name
        if ($Entry) { $Accounts.Remove($named); Save-Accounts $Folder $Accounts | Out-Null }
        else { return Save-PlainName $Folder $Accounts $named.name }
    }
    if (-not $Entry) {
        $Entry = New-Account $Ip $Folder $Accounts $Name
        if (-not $Entry) {
            if (-not $Name) { $Name = Ask-Name '' }
            return Save-PlainName $Folder $Accounts $Name
        }
    }
    $reclaimed = $false
    while ($true) {
        $reply = Invoke-Account $Ip $Folder "LOGIN2 $($Entry.token)"
        if ($null -eq $reply) { return [pscustomobject]@{ Uid = $null; Name = $Entry.name } }
        if ($reply -eq 'DENIED' -and -not $reclaimed) {
            # A name the admin released can be claimed again (it keeps its picks and statistics).
            $claim = Invoke-Account $Ip $Folder "CLAIM $($Entry.name)"
            if ($claim -cnotmatch '^OK ([0-9a-f]{64})$') {
                throw "The server does not accept the saved key for $($Entry.name). If it was lost, ask the server admin to run: roe_server account reset `"$($Entry.name)`""
            }
            $Entry.token = $Matches[1]
            Save-Accounts $Folder $Accounts | Out-Null
            $reclaimed = $true
            continue
        }
        if ($reply -cmatch '^OK ([0-9]+) (.+)$') {
            $uid = $Matches[1]
            $Entry.name = $Matches[2]
            $Entry.last_used = Get-UnixTime
            $sorted = @($Accounts | Sort-Object -Property last_used -Descending)
            $Accounts.Clear()
            foreach ($a in $sorted) { [void]$Accounts.Add($a) }
            Save-Accounts $Folder $Accounts | Out-Null
            Write-Host "Logged in as $($Entry.name)"
            return [pscustomobject]@{ Uid = $uid; Name = $Entry.name }
        }
        Stop-Refused $reply $Entry.name
    }
}

# --- Joining: the steps of a join, for join.cmd and join-gui.cmd ------------------------------
# The game folder as a full path; throws when it has no Europa_Client.exe or another build.
function Get-GameFolder([string]$Folder) {
    if (-not (Test-Client $Folder)) { throw "No Europa_Client.exe in: $Folder" }
    $Folder = (Resolve-Path -LiteralPath $Folder).Path
    if ($expectedSha -notcontains (Get-Sha256 (Join-Path $Folder 'Europa_Client.exe'))) {
        throw 'This is a different game build. The server needs 2022-0.2.989.0 x64: the Europa_Client.exe of the main game folder or of XVersion.'
    }
    return $Folder
}
# The host of a server address. The game only connects to lobby port 8001, so a second server
# needs its own address.
function Get-ServerHost([string]$Server) {
    if ($Server -match '^(.+):(\d{1,5})$') {
        if ([int]$Matches[2] -ne 8001) { throw "The game only connects to port 8001. Enter the server address without :$($Matches[2]) (a second server runs on its own address)." }
        return $Matches[1]
    }
    return $Server
}
# The IPv4 addresses of a host. A domain is resolved again at every join (it is saved as typed);
# it may have several: the game uses the first, the rules allow all.
function Resolve-ServerIps([string]$HostName) {
    $address = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$address) -and $address.AddressFamily -eq 'InterNetwork') { return ,[string[]]@($address.ToString()) }
    $ips = @([Net.Dns]::GetHostAddresses($HostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() })
    if (-not $ips.Count) { throw "Cannot resolve $HostName to an IPv4 address." }
    return ,[string[]]$ips
}
# What runs on the server now, for the line after the login and while the game runs: every
# region with its numbers (STATS), the INFO line only from a server without STATS; INFO's
# restart notice either way.
function Format-ServerNow([string]$Info, [string]$Stats) {
    $regions = Format-Stats $Stats
    if (-not $regions) { return Format-ServerInfo $Info }
    $text = "On the server now: $regions."
    if ($Info -match '(^| )restarting=[1-9]') { $text += ' It restarts for an update soon; new searches are refused until then.' }
    return $text
}
# Where a server's accounts and certificate pin are kept.
function Get-AccountFolder([string]$Server) { return Join-Path $joinRoot (Get-ServerFolderName $Server) }
# The server's name (INFO), whether this script is new enough (VERSION: TooOld the reason to stop,
# Notice a newer one), where else the game goes for it (ADDRESSES without ServerIps; $null: no
# answer, or Addresses false) and who plays where (STATS: Regions). Info is $null from a server
# without an account service, which answers none of them.
function Connect-Server([string]$Ip, [string]$Folder, [string[]]$ServerIps, [bool]$Addresses = $true, [string]$Script = 'join.cmd') {
    $result = [pscustomobject]@{ Info = $null; Name = ''; TooOld = ''; Notice = $null; Listed = $null; Regions = '' }
    $result.Info = Invoke-Account $Ip $Folder 'INFO'
    if (-not $result.Info) { return $result }
    if ($result.Info -match '^OK ') { $result.Name = Get-InfoServerName $result.Info }
    $versionReply = $null
    try { $versionReply = Invoke-Account $Ip $Folder 'VERSION' } catch { }
    try { $result.Notice = Get-VersionNotice $versionReply $joinVersion $Script } catch { $result.TooOld = $_.Exception.Message }
    if ($result.TooOld) { return $result }
    if ($Addresses) {
        $listed = $null
        try { $listed = Get-ServerAddresses (Invoke-Account $Ip $Folder 'ADDRESSES') } catch { }
        if ($null -ne $listed) { $result.Listed = [string[]]@($listed | Where-Object { $ServerIps -notcontains $_ }) }
    }
    try { $result.Regions = Format-Stats (Get-ServerStats $Ip $Folder) } catch { }
    return $result
}
# The firewall step (Firewall: the rules on). The game may talk to this computer and to the
# servers joined so far and the addresses they list, nothing else. The rules name addresses only,
# no ports or protocols, so the voice relay (UDP 10101 on the same server) and any match port are
# allowed too. Saves into ServerList what Server lists (Listed) and its addresses once the rules
# took them. Returns Programs and Check: the arguments for Confirm-FirewallState (Wanted, RulesOn,
# Step: the administrator step's result) or $null when there is nothing to check.
function Update-Firewall([string]$Client, $ServerList, [string]$Server, [string[]]$ServerIps, $Listed, [bool]$Firewall) {
    $programs = Get-GamePrograms $Client
    $folder = Get-FolderRules $Client $programs
    # This computer (127.0.0.0/8) is always allowed by every rule set (ours and play.cmd's), so a
    # local server needs no change; a second game on this PC starts while the first one runs.
    $remoteIps = @($ServerIps | Where-Object { $_ -notlike '127.*' })
    $localOnly = -not $remoteIps.Count
    $addressesDone = $true  # false when the rules could not take the list: it is not saved then
    $check = $null
    if (-not $Firewall) {
        if (($folder.Own.Count -or $folder.Other.Count) -and $localOnly -and @(Get-RunningGame $programs).Count) {
            Write-Host 'The game runs already; rules for this folder stay as they are (they allow this computer).'
        } elseif ($folder.Own.Count -or $folder.Other.Count) {
            # Rules made while they were on (or play.cmd's) would block a server not trusted then.
            Assert-GameClosed $programs
            Write-Host ''
            Write-Host 'Firewall rules are off, but rules for this game folder are left that may block the server.'
            try { Remove-Rules (@($folder.Own) + @($folder.Other)) "for $Client" } catch { Write-Host $_.Exception.Message }
            $check = [pscustomobject]@{ Wanted = $null; RulesOn = $false; Step = $null }
        } elseif ($folder.Fixed.Count) {
            $check = [pscustomobject]@{ Wanted = $null; RulesOn = $false; Step = $null }
        }
    } else {
        # Servers used before stay trusted: the rules name them ("servers a b"). This server's
        # addresses and its list are added, what it listed before and no longer lists goes.
        $trusted = @(Get-TrustedServers $folder.Own)
        $mine = @($ServerList | Where-Object { (Get-ServerFolderName $_.address) -eq (Get-ServerFolderName $Server) })
        $previous = @($mine | ForEach-Object { $_.addresses })
        $previousIps = @($mine | ForEach-Object { $_.ips })
        $wanted = Get-TrustedUpdate $trusted $remoteIps $Listed $previous (Get-KeptAddresses $ServerList $Server) $previousIps
        $current = Test-RulesCurrent $folder.Own $programs.Count $wanted
        $step = $null
        if ((-not $current -or $folder.Other.Count) -and $localOnly -and @(Get-RunningGame $programs).Count) {
            Write-Host 'The game runs already (play.cmd?); the firewall rules stay as they are: they allow this computer.'
            $addressesDone = $false
        } elseif (-not $current -or $folder.Other.Count) {
            Assert-GameClosed $programs
            $gone = @($trusted | Where-Object { $wanted -notcontains $_ })
            Write-Host ''
            Write-Host "Firewall: the game will be allowed to reach only this computer and $($wanted -join ', ')."
            if ($gone.Count) { Write-Host "No longer listed by the server: $($gone -join ', ')." }
            $others = @($folder.Other | Where-Object { $_.Local })
            if ($others.Count) { Write-Host "Block rules of other programs for this game are removed: $(@($others | ForEach-Object { '"' + $_.DisplayName + '"' }) -join ', ')." }
            if (Test-Administrator) { Write-Host 'Running as administrator: the rules are set now.' }
            else { Write-Host 'Administrator approval is needed for that (a Windows prompt appears).' }
            $step = Set-FolderRules $programs $folder $wanted
            if (-not $step.Ok) { $addressesDone = $false }
        }
        $problems = @(Get-FirewallProblems)
        if ($problems.Count) { Write-Host ('Warning: Windows does not apply the firewall rules: ' + ($problems -join '; ') + '.') -ForegroundColor Yellow }
        foreach ($product in (Get-OtherFirewalls)) { Write-Host "$product says it runs the firewall: if the game cannot connect, allow it there for $($wanted -join ', ')." -ForegroundColor Yellow }
        if (-not $problems.Count -and -not ($localOnly -and @(Get-RunningGame $programs).Count)) {
            # Checked every time: a declined or silently failed prompt, rules turned off, and block
            # rules of other programs all leave the game cut off from the server.
            $check = [pscustomobject]@{ Wanted = $wanted; RulesOn = $true; Step = $step }
        }
    }
    $keep = $null; $keepIps = $null  # saved only once the rules (if on) took them
    if ($addressesDone) { $keep = $Listed; $keepIps = [string[]]@($remoteIps) }
    Set-ServerAddresses $ServerList $Server $keep $keepIps
    return [pscustomobject]@{ Programs = $programs; Check = $check }
}
# Removes every rule of join.cmd and the server launcher.
function Reset-AllRules {
    $all = @(Get-NetFirewallRule -Group 'ROE2022-*' -ErrorAction SilentlyContinue)
    Assert-GameClosed @($all | ForEach-Object { ($_ | Get-NetFirewallApplicationFilter).Program } | Sort-Object -Unique)
    Remove-Rules $all 'of join.cmd and the server launcher'
    Write-Host 'The next join creates new rules that trust only its own server.'
}
# Removes the rules of a game folder (and other rules that block its programs).
function Remove-FolderRules([string]$Client) {
    if (-not (Test-Client $Client)) { return }
    $programs = Get-GamePrograms $Client
    $folder = Get-FolderRules $Client $programs
    Assert-GameClosed $programs
    Remove-Rules (@($folder.Own) + @($folder.Other)) "for $Client"
}
# A server without an account service takes the name on the lobby port for the next client from
# this address.
function Register-LobbyName([string]$Ip, [string]$Name) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $pending = $tcp.BeginConnect($Ip, $lobbyPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(5000) -or -not $tcp.Connected) {
            throw "No server answers at ${Ip}:$lobbyPort. Check the address, that the server runs with -Bind 0.0.0.0, and the host's firewall (TCP $lobbyPort and $accountPort, UDP 18001, and the ports above it on a server with several maps or match processes)."
        }
        $tcp.EndConnect($pending)
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 5000
        $request = [Text.Encoding]::UTF8.GetBytes("ROE-NAME $Name`n")
        $stream.Write($request, 0, $request.Length)
        $buffer = New-Object byte[] 128
        $reply = ''
        try { $reply = [Text.Encoding]::UTF8.GetString($buffer, 0, $stream.Read($buffer, 0, $buffer.Length)).Trim() } catch { }
        if ($reply -eq 'OK') { Write-Host "Name registered: $Name" }
        elseif ($reply) { Write-Host "The server did not accept the name ($reply). You will play under the default name." }
        else { Write-Host 'This server does not take names. You will play under the default name.' }
    } finally {
        $tcp.Close()
    }
}
# Logs in with Entry (Select-Account's answer; $null: a new account, named Name if given). Servers
# with accounts hand out a one-time ticket that the game passes on as its -uid; a server without an
# account service gets the name on the lobby port (Register-LobbyName). Returns Uid ('1' without
# accounts), Name (the account's current name) and Accounts (the server has an account service).
function Connect-Account([string]$Ip, [string]$Folder, $Accounts, $Entry, [string]$Name) {
    $login = Invoke-Login $Ip $Folder $Accounts $Entry $Name
    $service = $null -ne $login.Uid
    if (-not $service) { Register-LobbyName $Ip $login.Name }
    $uid = if ($service) { $login.Uid } else { '1' }
    return [pscustomobject]@{ Uid = $uid; Name = $login.Name; Accounts = $service }
}
# Our voice DLL in (VoicePick: Get-VoiceChoice's Pick, $null: no voice), then the game, connected
# to the server. Returns Process and VoiceOn: when true, Restore-Voice once the game exits.
function Start-Game([string]$Client, [string]$Uid, [string]$Ip, $VoicePick) {
    Write-Host ''
    Write-Host 'Starting the game.'
    $voiceOn = $false
    if ($VoicePick -and $VoicePick.Hash) { $voiceOn = Install-Voice $Client $VoicePick.Dll $VoicePick.Hash }
    try {
        $game = Start-Process -FilePath (Join-Path $Client 'Europa_Client.exe') -WorkingDirectory $Client -PassThru `
            -ArgumentList @('-language=en', '-garena', "-uid=$Uid", "-server=${Ip}:$lobbyPort")
    } catch {
        if ($voiceOn) { Restore-Voice $Client 15 | Out-Null }
        throw
    }
    return [pscustomobject]@{ Process = $game; VoiceOn = $voiceOn }
}

try {
    $settings = Read-Settings
    Restore-AllVoice  # ours left by a crash or a closed window: the original back first
    $arguments = Read-Arguments "$env:ROE_JOIN_ARGS"
    $command = $arguments.Command
    $givenName = $arguments.Name
    $givenServer = $arguments.Server
    if ("$env:ROE_JOIN_ARGS" -match '(^|\s)-Name(\s|$)' -and (-not $givenName -or $givenName.Length -gt 24 -or $givenName -match '[\x00-\x1f]')) {
        throw 'The name must be 1 to 24 characters without control characters.'
    }
    if ($command -and ($givenName -or $givenServer)) { throw 'Usage: join.cmd [-Server <address>] [-Name <name>] | firewall [on|off|reset] | voice [on|off] | export [FILE] | import FILE' }
    if ($command -match '^voice(\s+(on|off))?$') {
        $set = $Matches[2]
        if ($set) {
            $on = $set.ToLowerInvariant() -eq 'on'
            $settings | Add-Member -NotePropertyName voice -NotePropertyValue $on -Force
            if ($on) {
                # Asks for the DLL again (Enter keeps it) and checks it now, so the next start does not ask.
                $client = if (Test-Client $settings.client) { $settings.client } else { '' }
                $picked = Select-VoiceDll $settings.voice_dll $client $true
                if ($picked.Hash) { $settings | Add-Member -NotePropertyName voice_dll -NotePropertyValue $picked.Dll -Force }
            }
            $settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        }
        $state = if ($null -eq $settings.voice) { 'not asked yet' } elseif ($settings.voice) { 'on' } else { 'off' }
        $dll = if ($settings.voice_dll -and (Test-Path -LiteralPath $settings.voice_dll -PathType Leaf)) { $settings.voice_dll } else { Get-DefaultVoiceDll }
        $found = if (Test-Path -LiteralPath $dll -PathType Leaf) { 'found' } else { 'missing (it comes with the server package)' }
        Write-Host "Voice chat: $state. Our ${voiceFile}: $dll ($found). Commands: join.cmd voice on | off (on also asks for the DLL)"
        exit 0
    }
    if ($command -match '^(export|import)(\s+(.*))?$') {
        $action = $Matches[1].ToLowerInvariant()
        $file = "$($Matches[3])".Trim().Trim('"')
        if ($action -eq 'export') {
            if (-not $file) { $file = Join-Path (Get-Location).Path 'roe-join-accounts.json' }
            $file = [IO.Path]::GetFullPath($file)
            if ((Test-Path -LiteralPath $file) -and (Ask "$file exists. Overwrite it? (y/n)" 'n') -notmatch '^[yY]') { throw 'Cancelled.' }
            $done = Export-Accounts $joinRoot $settings $file
            Write-Host "Saved $($done.Accounts) accounts of $($done.Servers) servers in $file."
            Write-Host $backupWarning -ForegroundColor Yellow
            Write-Host 'On the other computer: join.cmd import <file> (or python3 join.py --import <file>).'
            exit 0
        }
        if (-not $file) { throw 'Usage: join.cmd import FILE' }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "No file: $file" }
        Write-Host $backupWarning -ForegroundColor Yellow
        $done = Import-Accounts $joinRoot $settings $file
        $settings | Add-Member -NotePropertyName servers -NotePropertyValue @($done.Servers) -Force
        $settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        Write-Host "Imported: $($done.Added) new accounts, $($done.Updated) updated (used more recently in the backup)."
        if ($done.Skipped.Count) { Write-Host "Skipped (another certificate): $($done.Skipped -join ', ')." }
        Write-Host 'You may delete the backup file now.'
        exit 0
    }
    if ($command) {
        if ($command -notmatch '^firewall(\s+(on|off|reset|status))?$') { throw 'Usage: join.cmd [-Server <address>] [-Name <name>] | firewall [on|off|reset] | voice [on|off] | export [FILE] | import FILE' }
        $action = if ($Matches[2]) { $Matches[2].ToLowerInvariant() } else { 'status' }
        $client = $settings.client
        if ($action -eq 'status') { Show-Firewall $client $settings.firewall; exit 0 }
        if ($action -eq 'reset') { Reset-AllRules; exit 0 }
        $settings | Add-Member -NotePropertyName firewall -NotePropertyValue ($action -eq 'on') -Force
        $settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        if ($action -eq 'on') { Write-Host 'Firewall rules on: the next join creates them.'; exit 0 }
        Remove-FolderRules $client
        Write-Host 'Firewall rules off: join.cmd no longer creates them (the game can reach the internet).'
        exit 0
    }
    Write-Host 'Ring of Elysium 2022: join a server'
    Write-Host ''

    # 1. The game.
    # Always asked (Enter keeps the last one): a second game folder, for example XVersion,
    # lets a second player join from the same PC.
    $guess = $settings.client
    if (-not (Test-Client $guess)) { $guess = 'C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium' }
    if (-not (Test-Client $guess)) { $guess = '' }
    $client = Get-GameFolder (Ask 'Game folder (the one with Europa_Client.exe)' $guess)

    # 2. Server and name.
    $serverList = @(Read-Servers $settings)
    $server = "$(Select-Server $serverList $givenServer)".Trim()
    if (-not $server) { throw 'A server address is needed.' }
    $hostName = Get-ServerHost $server
    $firewall = $settings.firewall
    $voice = $settings.voice
    $voiceDll = $settings.voice_dll
    $serverList = Add-ServerUse $serverList $server
    function Save-Settings { Save-JoinSettings $client $firewall $voice $voiceDll $serverList }
    $voiceChoice = Get-VoiceChoice $voice $voiceDll $client ''
    $voice = $voiceChoice.Voice
    $voiceDll = $voiceChoice.Dll
    $voicePick = $voiceChoice.Pick
    Save-Settings
    $serverIps = Resolve-ServerIps $hostName
    $serverIp = $serverIps[0]

    # The server's name, version, where else the game goes for it and who plays where, before the
    # firewall rules. A server without an account service answers none.
    Write-Host ''
    Write-Host "Contacting ${serverIp} ..."
    $folder = Get-AccountFolder $server
    $contact = Connect-Server $serverIp $folder $serverIps
    if ($contact.Info -match '^OK ') {
        if (Set-ServerName $serverList $server $contact.Name) { Save-Settings }
        if ("$($serverList[0].name)") { Write-Host "Connected to $(Get-ServerLabel $serverList[0])" }
    }
    # Too old for the server: stop before the game starts.
    if ($contact.TooOld) { throw $contact.TooOld }
    if ($contact.Notice) { Write-Host $contact.Notice -ForegroundColor Yellow }
    if ($contact.Regions) { Write-Host $contact.Regions }

    # 3. Firewall (optional, asked once).
    if ($null -eq $firewall) {
        Write-Host ''
        Write-Host 'join.cmd can add Windows Firewall rules so the game reaches only the servers you join'
        Write-Host '(it also tries the publisher''s old servers). That needs administrator approval when the allowed addresses change.'
        $firewall = (Ask 'Add the firewall rules? (y/n)' 'y') -match '^[yY]'
        Save-Settings
        Write-Host 'Change it later with: join.cmd firewall on | off | reset'
    }
    $rules = Update-Firewall $client $serverList $server $serverIps $contact.Listed $firewall
    if ($rules.Check) { Confirm-FirewallState $client $rules.Programs $rules.Check.Wanted $rules.Check.RulesOn $rules.Check.Step }
    Save-Settings

    # 4. Log in.
    $accountList = Read-Accounts $folder
    if ($accountList.Count -and -not $givenName -and (Update-AccountNames $serverIp $folder $accountList)) { Save-Accounts $folder $accountList | Out-Null }
    $login = Connect-Account $serverIp $folder $accountList (Select-Account $accountList $givenName) $givenName
    Save-Settings
    if ($login.Accounts) {
        $info = $null
        try { $info = Invoke-Account $serverIp $folder 'INFO' } catch { }
        $stats = $null
        try { $stats = Get-ServerStats $serverIp $folder } catch { }
        if ($info -match '^OK ') { Write-Host (Format-ServerNow $info $stats) }
    }

    # 5. The game.
    $game = Start-Game $client $login.Uid $serverIp $voicePick
    try {
        # While the game runs: the server's numbers every 30 s, in the window title and on one line
        # here that is written over each time.
        $width = 0
        while (-not $game.Process.WaitForExit(30000)) {
            if (-not $login.Accounts) { continue }
            $info = $null
            try { $info = Invoke-Account $serverIp $folder 'INFO' } catch { }
            if ($info -notmatch '^OK ') { continue }
            $stats = $null
            try { $stats = Get-ServerStats $serverIp $folder } catch { }
            $line = Format-ServerNow $info $stats
            try { $Host.UI.RawUI.WindowTitle = "Ring of Elysium: $line" } catch { }
            $text = "[{0:HH:mm}] {1}" -f (Get-Date), $line
            if (-not $width) { Write-Host '' }  # set apart from the lines above
            Write-Host ("`r" + $text.PadRight($width)) -NoNewline -ForegroundColor Cyan
            $width = [Math]::Max($width, $text.Length)
        }
        if ($width) { Write-Host '' }
    } finally {
        if ($game.VoiceOn) { Restore-Voice $client 15 | Out-Null }
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host ('Could not join: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
