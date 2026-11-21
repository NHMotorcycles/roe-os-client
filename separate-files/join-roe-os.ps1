# join-roe-os.ps1: the PowerShell part of join-roe-os.cmd as a file of its own, for virus scanners
# that flag the single file. Keep join-roe-os.cmd of this folder next to it and start that; it sets
# what this code reads (ROE_JOIN_SELF, ROE_JOIN_CODE, ROE_JOIN_ARGS, ROE_JOIN_WINDOW).
# Generated from join-roe-os.cmd by tools/make_separate_files.py: change that file, not this one.

# Join a Ring of Elysium 2022 server (roe_server) as a player.
#
# This one file is all a player needs besides the game. Double-click it: a window opens with the
# servers (on the first start roe-os.de, "Add server..." for another one) and who plays where on
# the selected one; the accounts on that server ("Create a new account" makes one); the game
# folder (the Ring of Elysium folder, with a DirectX 12 box for its XVersion folder); voice chat;
# and Play. Under "Advanced": the firewall rules (on, off, reset, show), the account backup
# (export, import) and the log; for an account with GM rights on the selected server (ROLE) also
# "Open the admin page" (for others it is not shown; the server checks the rights again).
#
# In a command prompt it is the console version: join-roe-os.cmd with the arguments below, or typed
# without any, works in the prompt. join-roe-os.cmd --console forces the console (for example from
# PowerShell, whose .\join-roe-os.cmd counts as a double-click), join-roe-os.cmd --window the window. Both run
# the same functions below and share the settings, accounts and keys (%APPDATA%\roe-join.json,
# %APPDATA%\roe-join\).
#
# The window asks join-roe-os.cmd's questions as dialogs and shows its messages in the status line. The
# network, the firewall step (with the Windows administrator prompt) and the wait for the game run
# in a background runspace, so the window never freezes. What happened is in
# %APPDATA%\roe-join\gui.log ("Open the log", or "Details"). Windows PowerShell 5.1 and .NET
# Framework (WPF) only, as on every Windows 10 and 11.
#
# The console asks for
#   - the game folder (the last one is the default),
#   - the server (arrow keys and Enter; the servers joined before by name and address, the most
#     recently used on top, on the first start roe-os.de; the last entry asks for another address),
#   - the account to play with (arrow keys and Enter; the most recently used on top, the last
#     entry creates a new one),
# then keeps the game from reaching anything but the servers joined so far and the addresses
# each server names for its matches (Windows Firewall, asks for administrator approval only
# when the allowed addresses change), logs in to the server and starts the game. Answers are remembered in %APPDATA%\roe-join.json (the servers with their name and last use
# in "servers"). join-roe-os.cmd -Server <address> joins that server without the menu.
#
# Accounts: a new account gets a secret key from the server. The keys are kept with each
# account's current name in %APPDATA%\roe-join\<server>\accounts.json; copy that folder to play
# with the same accounts on another computer. With first-login on, the server names a new
# account (newaccount and 4 digits, for example newaccount1234) and the game asks for the real
# name; otherwise join-roe-os.cmd asks for it. join-roe-os.cmd -Name <name> picks the saved account of that
# name, or claims the name for a new one, without the menu. The server's certificate is
# remembered on first contact (server.pin there) and a different one is refused.
#
# The firewall rules are optional (asked once). From a command prompt:
#   join-roe-os.cmd firewall          shows the rules, the trusted servers, whether Windows applies them
#                              and where a running game is connected
#   join-roe-os.cmd firewall on|off   rules from the next join on, or none (removes this folder's rules)
#   join-roe-os.cmd firewall reset    removes the rules of every game folder and forgets the servers;
#                              the next join trusts only its own server
# After the step join-roe-os.cmd checks that the rules apply and that no block rule of another program
# names the game (those are removed with the step). When something is wrong (the prompt declined
# or never shown, the step failed, a policy rule) it says what to do and asks before the game
# starts. Run as administrator, it sets the rules without a prompt.
#
# Voice chat (on by default, asked once; join-roe-os.cmd voice on|off changes it): our GCloudVoice.dll
# replaces the game's while the game runs. It comes from voice\ next to this file, or from the
# folder the player gave (asked when it is missing and by join-roe-os.cmd voice on; saved as voice_dll,
# then used without asking). The original is kept with its hash in
# %APPDATA%\roe-join\voice-backup\ and put back when the game exits, or at the next start after a
# crash or a closed window.
#
# Game files: before a join, join-roe-os.cmd checks the files other launchers and lobby patchers change
# (the .sfc archives they append to, the lobby caches, GCloudVoice.dll) against the Steam install
# and looks for files a clean install does not have (proxy DLLs such as dinput8.dll, data_exp.vfs).
# When one differs it says which and how to repair it (Steam's Verify integrity of game files),
# and starts the game only when the player chooses to start anyway. The hashes are kept by size
# and write time in %APPDATA%\roe-join\file-check.json, so only the first start hashes the files.
# join-roe-os.cmd --skip-file-check leaves the check out.
#
# The server can name the oldest version of this script it takes (VERSION); an older one stops
# before the game starts and says where to get the new one.
#
# GM accounts: join-roe-os.cmd admin (with -Server and -Name as for a join) opens the server's admin page in
# the browser with a one-time login link (ROLE, then WEB; the server sends the page's address or
# it is https://admin.<the server's domain>). Other accounts are told they have no GM rights.
#
# Account backup: join-roe-os.cmd export [FILE] writes every server's accounts (their keys), certificate
# pin and name into one file (default roe-join-accounts.json here); join-roe-os.cmd import FILE merges
# one into this computer. join-roe-os.py reads and writes the same file (--export, --import).
#
# Nothing else in the game folder is changed.

# The administrator step of the firewall rules: join-roe-os.cmd starts this file (a .ps1 copy of it) as
# administrator with -FirewallStep and a file that names the rules to create and remove.
param([string]$FirewallStep = '')
$ErrorActionPreference = 'Stop'
# Tested Europa_Client.exe builds of 2022-0.2.989.0 x64: the root folder (DX11) and XVersion (DX12).
$expectedSha = @('2dca9b1e122e21363e14eeeb2372598c773205a907ed8d2b2d54a7229ad6ba18', 'e076dddcab4b48d52b920a84bbee125c8b452900ae90cea2f190f2e3654ff81d')
# This script's version; the server can ask for a newer one (VERSION). The same number as join-roe-os.py's
# and roe_server's (src/lobby/accounts.hpp kJoinScriptVersion).
$joinVersion = '1.0'
$joinUrl = 'https://github.com/mschnati/roe-os-client'
$lobbyPort = 8001
$accountPort = 8002
$settingsPath = Join-Path $env:APPDATA 'roe-join.json'
$joinRoot = Join-Path $env:APPDATA 'roe-join'

# roe-join.json as the console and the window write it.
function Save-JoinSettings([string]$Client, $Firewall, $Voice, $VoiceDll, $Servers) {
    $values = [ordered]@{ client = $Client; firewall = $Firewall; voice = $Voice; voice_dll = $VoiceDll; servers = @($Servers) }
    [pscustomobject]$values | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
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
# The separate files (separate-files/, for virus scanners that flag this one file): join-roe-os.ps1
# holds this code, and its launcher sets ROE_JOIN_CODE to it. In this file: ROE_JOIN_SELF.
function Get-JoinCodePath { if ($env:ROE_JOIN_CODE) { return $env:ROE_JOIN_CODE }; return $env:ROE_JOIN_SELF }
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
# Runs a firewall step as administrator: directly when join-roe-os.cmd runs as one, else through a
# Windows prompt. The step is data (Create: rules with Name, Group, Description, Program and
# RemoteAddress; Remove: rule names) in a file that a .ps1 copy of join-roe-os.cmd reads with
# -FirewallStep (Invoke-FirewallStep). Returns Ok and Reason: done; declined (the prompt said no,
# or Windows denies it on this account); not-admin (it ran without administrator rights, User
# Account Control off on a standard account); failed (Detail: the error); no-start (Windows did
# not start it).
function Invoke-Elevated($Plan, [bool]$Admin = (Test-Administrator)) {
    $folder = Join-Path $env:APPDATA 'roe-join'
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    $id = [Guid]::NewGuid().ToString('N')
    $step = Join-Path $folder "firewall-step-$id.json"
    $script = Join-Path $folder "firewall-step-$id.ps1"
    $log = "$step.log"
    $code = $null
    try {
        Set-Content -LiteralPath $step -Value (ConvertTo-Json -InputObject $Plan -Depth 5) -Encoding UTF8
        # The bytes only: File.Copy would take a download's mark along, and PowerShell would refuse it.
        [IO.File]::WriteAllBytes($script, [IO.File]::ReadAllBytes((Get-JoinCodePath)))
        if ($Admin) {
            & powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $script -FirewallStep $step | Out-Host
            $code = $LASTEXITCODE
        } else {
            $code = (Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', "`"$script`"", '-FirewallStep', "`"$step`"")).ExitCode
        }
    } catch {
        $native = $_.Exception.InnerException.NativeErrorCode
        if ($null -eq $native) { $native = $_.Exception.NativeErrorCode }
        $reason = if ($native -eq 1223 -or ($null -eq $native -and $_.Exception.Message -match 'cancel')) { 'declined' } else { 'no-start' }
        return [pscustomobject]@{ Ok = $false; Reason = $reason; Detail = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $script, $step -ErrorAction SilentlyContinue
    }
    $detail = ''
    if (Test-Path -LiteralPath $log) { $detail = "$(Get-Content -LiteralPath $log -Raw)".Trim(); Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue }
    if ($code -eq 0) { return [pscustomobject]@{ Ok = $true; Reason = 'done'; Detail = '' } }
    if ($code -eq 3) { return [pscustomobject]@{ Ok = $false; Reason = 'not-admin'; Detail = '' } }
    return [pscustomobject]@{ Ok = $false; Reason = 'failed'; Detail = $detail }
}
# The step itself, in the administrator's PowerShell: creates the rules of the file at Path (if one
# fails, the ones it created go again and nothing is removed), then removes the named rules.
# Returns the exit code: 0 done, 1 failed (the error in Path.log), 3 no administrator rights.
function Invoke-FirewallStep([string]$Path) {
    if (-not (Test-Administrator)) { return 3 }
    $created = @()
    try {
        $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        try {
            foreach ($rule in @($plan.Create | Where-Object { $_ })) {
                New-NetFirewallRule -Name $rule.Name -DisplayName $rule.Name -Group $rule.Group -Description $rule.Description -Direction Outbound -Action Block `
                    -Program $rule.Program -RemoteAddress @($rule.RemoteAddress) -Profile Any -Enabled True | Out-Null
                $created += $rule.Name
            }
        } catch {
            foreach ($name in $created) { Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue }
            throw
        }
        foreach ($name in @($plan.Remove | Where-Object { $_ })) { Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue }
    } catch {
        Set-Content -LiteralPath "$Path.log" -Value "$_"
        return 1
    }
    return 0
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
        if ($missing.Count) { $problems += "no join-roe-os.cmd rule for $($missing.Count) of $($Programs.Count) game programs (for example $(Split-Path -Leaf $missing[0]))" }
        if ($off.Count) { $problems += "the join-roe-os.cmd rule is off for $($off.Count) game programs" }
        if ($stale.Count) { $problems += "the join-roe-os.cmd rules of $($stale.Count) game programs trust other servers than $($Wanted -join ', ')" }
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
        $lines += 'join-roe-os.cmd already runs as administrator: check the error above, or run "join-roe-os.cmd firewall" to see the rules.'
    } else {
        $lines += 'Right-click join-roe-os.cmd > Run as administrator, or in a command prompt opened with "Run as administrator":'
        $lines += "  `"$Self`""
        $lines += 'On a standard Windows account this needs an administrator''s password.'
    }
    $lines += 'Or turn the rules off with "join-roe-os.cmd firewall off" (then the game can reach the internet).'
    return $lines
}
function Get-RuleNames($Rules) {
    return [string[]]@($Rules | Where-Object { $_ } | ForEach-Object { $_.Name })
}
# A folder's rules of this launcher (Own), and others that block one of its programs (Other):
# the server launcher's for this folder, ones made for another folder, or local block rules of
# other programs. Block rules win, so those would block the server too. Fixed: block rules of a
# policy or security product, which join-roe-os.cmd cannot remove.
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
    if ($problems.Count -gt 5) { Write-Host "  - and $($problems.Count - 5) more (join-roe-os.cmd firewall shows them)" -ForegroundColor Yellow }
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
    Write-Host ("Rules of join-roe-os.cmd: $($join.Count) for $(@($join | ForEach-Object { $_.Group } | Sort-Object -Unique).Count) game folders; " +
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
    Write-Host "join-roe-os.cmd creates rules: $state. Commands: join-roe-os.cmd firewall on | off | reset"
}
# The rules that let a folder's programs reach only this computer and the trusted servers. The
# new rules are created before the old ones go; if that fails, the new ones are removed again
# and the old ones stay.
function Set-FolderRules([string[]]$Programs, $Folder, [string[]]$Trusted) {
    $wanted = 'servers ' + ($Trusted -join ' ')
    $ranges = [string[]]@(Get-BlockedRanges $Trusted)
    $generation = [DateTime]::UtcNow.ToString('yyMMddHHmmss')
    $create = @()
    for ($index = 0; $index -lt $Programs.Count; $index++) {
        $create += [pscustomobject]@{ Name = "$($Folder.Group)-$generation-$index"; Group = $Folder.Group; Description = $wanted; Program = $Programs[$index]; RemoteAddress = $ranges }
    }
    return Invoke-Elevated ([pscustomobject]@{ Create = $create; Remove = (Get-RuleNames (@($Folder.Own) + @($Folder.Other))) })
}
function Remove-Rules($Rules, [string]$What) {
    $Rules = @($Rules | Where-Object { $_ })
    if (-not $Rules.Count) { Write-Host "No firewall rules $What."; return }
    $prompt = if (Test-Administrator) { '' } else { ' (a Windows prompt appears)' }
    Write-Host "Removing $($Rules.Count) firewall rules $What$prompt."
    $step = Invoke-Elevated ([pscustomobject]@{ Create = @(); Remove = (Get-RuleNames $Rules) })
    if (-not $step.Ok) { throw ('The firewall rules were not removed. ' + (Get-ElevationNote $step)) }
    Write-Host 'Removed.'
}

# --- Account backup -------------------------------------------------------------------------
# One JSON file with every server's accounts (names, keys, last use), certificate pin, address and
# name, the same for join-roe-os.cmd and join-roe-os.py: {"format": "roe-join-accounts", "version": 1,
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
        throw "$File is no account backup of join-roe-os.cmd or join-roe-os.py."
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
# Where our DLL is looked for without asking: next to join-roe-os.cmd, then in its voice folder.
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
    $text = "The game's original $voiceFile, saved by join-roe-os.cmd before it put in the one for voice chat.`r`n" +
        "join-roe-os.cmd puts it back when the game exits. To do it by hand: copy $voiceFile from this folder into`r`n$Client`r`n" +
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
        Write-Host "Voice chat: cannot read $target ($($_.Exception.Message)). Close the game and start join-roe-os.cmd again, or: $verifyHint." -ForegroundColor Yellow
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
    Write-Host "Voice chat: could not put the original $voiceFile back in $Client ($problem). Close the game and start join-roe-os.cmd again (it puts it back first), or: $verifyHint." -ForegroundColor Yellow
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
    # The saved DLL, or when it is gone (or none is saved) the one next to join-roe-os.cmd.
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
# kept; a yes without a DLL asks again next start. Option: join-roe-os.cmd voice on|off ('on' asks for
# the DLL again).
function Get-VoiceChoice($Voice, [string]$Dll, [string]$Client, [string]$Option) {
    $asked = $false
    if ($Option) { $Voice = $Option -eq 'on' }
    elseif ($null -eq $Voice) {
        Write-Host ''
        Write-Host "Voice chat needs our $voiceFile in the game folder while the game runs (the original is put back afterwards)."
        $Voice = (Ask 'Use voice chat? (y/n)' 'y') -match '^[yY]'
        $asked = $true
        Write-Host 'Change it later with: join-roe-os.cmd voice on | off'
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

# --- Game files changed by other launchers ---------------------------------------------------
# Other launchers and lobby patchers change files of the Ring of Elysium folder (an XVersion
# folder uses its parent's): blocks appended to the .sfc archives (menus, lobby banners and
# images, chat texts, the intro video, the DirectX 12 notice) and the lobby room's caches. Their
# size and SHA-256 in the Steam install of 2022-0.2.989.0. Only these are hashed (about 290 MB,
# once: the hashes are kept by size and write time in %APPDATA%\roe-join\file-check.json).
$originalFiles = @(
    @{ Path = 'SFC\Common.sfc'; Size = 24781543; Sha = '8c220227044411b0282ca08196f68f78183bfe692b1ffdfa6bb9ed41868d0e35' },
    @{ Path = 'SFC\TableBin.sfc'; Size = 29917290; Sha = 'd665fec68ce52352fcd9f232d3447fafec35a079beb91f514e612733ca1cd288' },
    @{ Path = 'SFC\UI.sfc'; Size = 145656512; Sha = 'c6ea81c7bce90f9fd370b3f1fe6dce303279ce3b263573ad9b29c874675b07a2' },
    @{ Path = 'data_dyn.sfc'; Size = 2432544; Sha = '644861de1b3be6b16af2549ceae66a20f258dea057299c989cff4f3c9fae4cf9' },
    @{ Path = 'data_org_dyn.sfc'; Size = 2432544; Sha = '644861de1b3be6b16af2549ceae66a20f258dea057299c989cff4f3c9fae4cf9' },
    @{ Path = 'Cache\otherbin.sfc'; Size = 82786448; Sha = 'fdf4844a879acc383242b4264661e6c7700ff2e564b0a2cd57fa5aa9f07b91e3' },
    @{ Path = 'Cache\Data\world\ActorCreationScreen\ActorCreationScreen.sfc'; Size = 1210287; Sha = 'c60273c83ae486fc854bd6848a263c65c2871c2b6d7e5452269e4c059d99626d' }
)
# The game's own GCloudVoice.dll: the main folder's and XVersion's (both signed by Tencent). Ours
# (the voice backup record's "installed") is expected while voice chat is on.
$originalVoiceSha = @('1444509a07c560b4f72539cc80b5fe980770566bb7d35f203db9251e850c27ef', 'bc174a98d8899728ec51de63553c7c4a368ccd2d6729f012a2349e69335d9bd4')
# Files a clean install does not have: a lobby patcher's overlay archive and DLLs that Windows
# loads into the game in place of its system DLLs (none of these names is part of the game).
$addedFiles = @('data_exp.vfs', 'dinput8.dll', 'dinput.dll', 'version.dll', 'winmm.dll', 'winhttp.dll', 'wininet.dll',
    'dxgi.dll', 'd3d9.dll', 'd3d10.dll', 'd3d11.dll', 'd3d12.dll', 'ddraw.dll', 'dsound.dll', 'xinput1_3.dll', 'xinput1_4.dll',
    'xinput9_1_0.dll', 'opengl32.dll', 'iphlpapi.dll', 'ws2_32.dll', 'wsock32.dll', 'hid.dll', 'msimg32.dll')
$fileCheckPath = Join-Path $joinRoot 'file-check.json'
function Read-FileCheckCache {
    $cache = @{ Files = @{}; Changed = $false }
    try {
        $read = Get-Content -LiteralPath $fileCheckPath -Raw | ConvertFrom-Json
        foreach ($p in $read.files.PSObject.Properties) { $cache.Files[$p.Name] = $p.Value }
    } catch { }
    return $cache
}
function Save-FileCheckCache($Cache) {
    if (-not $Cache.Changed) { return }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fileCheckPath) | Out-Null
        [pscustomobject]@{ files = $Cache.Files } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fileCheckPath -Encoding UTF8
    } catch { }
}
# A file's SHA-256 (Info: its IO.FileInfo), from Cache while its size and write time are the same.
function Get-CachedSha([IO.FileInfo]$Info, $Cache) {
    $key = $Info.FullName.ToLowerInvariant()
    $time = $Info.LastWriteTimeUtc.Ticks
    $entry = $Cache.Files[$key]
    if ($entry -and [int64]$entry.size -eq $Info.Length -and [int64]$entry.time -eq $time -and "$($entry.sha256)") { return "$($entry.sha256)" }
    $sha = Get-Sha256 $Info.FullName
    $Cache.Files[$key] = [pscustomobject]@{ size = $Info.Length; time = $time; sha256 = $sha }
    $Cache.Changed = $true
    return $sha
}
# The Ring of Elysium folder of a game folder: an XVersion folder's parent.
function Get-GameBase([string]$Client) {
    $trimmed = $Client.TrimEnd('\', '/')
    if ([IO.Path]::GetFileName($trimmed) -eq 'XVersion' -and (Split-Path -Parent $trimmed)) { return Split-Path -Parent $trimmed }
    return $trimmed
}
# What differs from the original install for the game folder Client: 'X changed', 'X missing' and
# 'X added', X below the Ring of Elysium folder. Empty when all is original.
function Get-ChangedGameFiles([string]$Client) {
    $base = Get-GameBase $Client
    $own = if ($base -ne $Client.TrimEnd('\', '/')) { 'XVersion\' } else { '' }
    $cache = Read-FileCheckCache
    $found = New-Object Collections.ArrayList
    foreach ($file in $originalFiles) {
        $info = New-Object IO.FileInfo (Join-Path $base $file.Path)
        if (-not $info.Exists) { [void]$found.Add("$($file.Path) missing") }
        elseif ($info.Length -ne $file.Size -or (Get-CachedSha $info $cache) -ne $file.Sha) { [void]$found.Add("$($file.Path) changed") }
    }
    $info = New-Object IO.FileInfo (Join-Path $Client $voiceFile)
    if (-not $info.Exists) { [void]$found.Add("$own$voiceFile missing") }
    else {
        $sha = Get-CachedSha $info $cache
        $record = Read-VoiceRecord (Get-VoiceBackupFolder $Client)
        if ($originalVoiceSha -notcontains $sha -and -not ($record -and $sha -eq "$($record.installed)")) { [void]$found.Add("$own$voiceFile changed") }
    }
    foreach ($folder in @(@($Client.TrimEnd('\', '/'), $base) | Select-Object -Unique)) {
        $prefix = if ($folder -ne $base) { 'XVersion\' } else { '' }
        foreach ($name in $addedFiles) { if (Test-Path -LiteralPath (Join-Path $folder $name) -PathType Leaf) { [void]$found.Add("$prefix$name added") } }
    }
    Save-FileCheckCache $cache
    return [string[]]$found.ToArray()
}
# The message for Get-ChangedGameFiles' list, as lines.
function Get-GameFilesText([string[]]$Found, [string]$Client) {
    $names = @($Found | Select-Object -First 4) -join ', '
    if ($Found.Count -gt 4) { $names += ", and $($Found.Count - 4) more" }
    $lines = @("Your game files were changed by another launcher ($names), so the game may not work with this server.")
    if (@($Found | Where-Object { $_ -notlike '* added' }).Count) { $lines += "Verify them in $verifyHint." }
    $added = @($Found | Where-Object { $_ -like '* added' } | ForEach-Object { $_ -replace ' added$', '' })
    if ($added.Count) { $lines += "Delete $($added -join ', ') in $(Get-GameBase $Client) (not part of the game; Steam's check leaves them)." }
    $lines += 'Then start again.'
    return $lines
}
# Before a join: when the game files are not the original ones, says so and asks whether to start
# anyway (no: the join stops). Skip: --skip-file-check.
function Confirm-GameFiles([string]$Client, [bool]$Skip) {
    if ($Skip) { Write-Host 'Game file check skipped (--skip-file-check).'; return }
    $found = @(Get-ChangedGameFiles $Client)
    if (-not $found.Count) { return }
    foreach ($line in (Get-GameFilesText $found $Client)) { Write-Host $line -ForegroundColor Yellow }
    if ((Ask 'Start the game anyway? (y/n)' 'n') -notmatch '^[yY]') { throw 'Cancelled: the game files are not the original ones. Verify them in Steam, then start again.' }
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
# 2 matches | NA (normal): offline". A region whose state (the field after the name) is down takes
# no new match (the game greys it out). Empty from an older server.
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
        if ($fields.Count -gt 6 -and $fields[6] -ceq 'down') { $parts += "$name ($($fields[1])): offline"; continue }
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
# The servers to offer: the saved ones, else (the first start) the default list, so a new player
# only picks one and plays.
function Get-OfferedServers($Settings) {
    $saved = @(Read-Servers $Settings)
    if ($saved.Count) { return $saved }
    $defaultServers = @(@{ address = 'roe-os.de'; name = 'ROE-OS' })
    return @($defaultServers | ForEach-Object { [pscustomobject]@{ address = $_.address; last_used = [int64]0; name = $_.name; addresses = [string[]]@(); ips = [string[]]@() } })
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
function Get-VersionNotice([string]$Reply, [string]$Have = $joinVersion, [string]$Script = 'join-roe-os.cmd') {
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

# --- Joining: the steps of a join, for the console and the window -----------------------------
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
function Connect-Server([string]$Ip, [string]$Folder, [string[]]$ServerIps, [bool]$Addresses = $true, [string]$Script = 'join-roe-os.cmd') {
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
# Removes every rule of join-roe-os.cmd and the server launcher.
function Reset-AllRules {
    $all = @(Get-NetFirewallRule -Group 'ROE2022-*' -ErrorAction SilentlyContinue)
    Assert-GameClosed @($all | ForEach-Object { ($_ | Get-NetFirewallApplicationFilter).Program } | Sort-Object -Unique)
    Remove-Rules $all 'of join-roe-os.cmd and the server launcher'
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
# --- The admin page (GM accounts) ------------------------------------------------------------
# An account's role on the server from the answer to ROLE: 'admin', 'gm', 'player', or '' (an
# unknown key, an older server without ROLE, no answer). The window shows "Open the admin page"
# for gm and admin (an admin is a GM that may also change the server's technical settings).
function Get-AccountRole([string]$Reply) {
    if ($Reply -ceq 'OK admin') { return 'admin' }
    if ($Reply -ceq 'OK gm') { return 'gm' }
    if ($Reply -ceq 'OK player') { return 'player' }
    return ''
}
# A domain (not an IP address): its admin page is https://admin.<domain> unless the server names another.
function Test-DomainHost([string]$HostName) {
    $address = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$address)) { return $false }
    return $HostName -match '^[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})+$'
}
# The admin page's one-time login link from the answer to WEB (Url), or why there is none (Problem).
function Get-AdminLink([string]$Reply, [string]$HostName) {
    $result = [pscustomobject]@{ Url = ''; Problem = '' }
    if ($Reply -ceq 'DENIED') { $result.Problem = 'This account has no GM rights on this server.'; return $result }
    if (-not $Reply -or $Reply -ceq 'NONE' -or $Reply -ceq 'INVALID') { $result.Problem = 'This server has no admin page.'; return $result }
    if ($Reply -ceq 'LIMIT') { $result.Problem = 'Too many attempts from this address. Try again in a minute.'; return $result }
    if ($Reply -ceq 'BANNED') { $result.Problem = 'This account or your address is banned on this server.'; return $result }
    if ($Reply -cnotmatch '^OK ([0-9a-f]{64}) (\S+)') { $result.Problem = "The account service answered: $Reply"; return $result }
    $ticket = $Matches[1]
    $base = $Matches[2]
    if ($base -ceq '-') {
        if (-not (Test-DomainHost $HostName)) {
            $result.Problem = 'This server has no admin page address (its admin can set one: roe_server set admin-url URL).'
            return $result
        }
        $base = "https://admin.$($HostName.ToLowerInvariant())"
    } else {
        try { $base = [Uri]::UnescapeDataString($base) } catch { $base = '' }
        if ($base -notmatch '^https?://[!-~]+$' -or $base.Length -gt 200) { $result.Problem = 'The server names no valid admin page address.'; return $result }
        $base = $base.TrimEnd('/')
    }
    $result.Url = "$base/login?ticket=$ticket"
    return $result
}
# Asks the server for the admin page's login link of a saved account (Entry): its role first, so
# a player's account never asks for a ticket.
function Request-AdminLink([string]$Ip, [string]$Folder, [string]$HostName, $Entry) {
    if (-not $Entry -or -not $Entry.token) { return [pscustomobject]@{ Url = ''; Problem = 'Choose a saved account of this server (one with a key).' } }
    if ((Get-AccountRole (Invoke-Account $Ip $Folder "ROLE $($Entry.token)")) -eq 'player') {
        return [pscustomobject]@{ Url = ''; Problem = 'This account has no GM rights on this server.' }
    }
    return Get-AdminLink (Invoke-Account $Ip $Folder "WEB $($Entry.token)") $HostName
}

# Our voice DLL in (VoicePick: Get-VoiceChoice's Pick, $null: no voice), then the game, connected
# to the server. Returns Process and VoiceOn: when true, Restore-Voice once the game exits.
function Start-Game([string]$Client, [string]$Uid, [string]$Ip, $VoicePick) {
    Write-Host ''
    Write-Host 'Starting the game.'
    $voiceOn = $false
    if ($VoicePick -and $VoicePick.Hash) { $voiceOn = Install-Voice $Client $VoicePick.Dll $VoicePick.Hash }
    try {
        $gameArgs = @('-language=en', '-garena', "-uid=$Uid", "-server=${Ip}:$lobbyPort")
        $game = Start-Process -FilePath (Join-Path $Client 'Europa_Client.exe') -WorkingDirectory $Client -PassThru -ArgumentList $gameArgs
    } catch {
        if ($voiceOn) { Restore-Voice $Client 15 | Out-Null }
        throw
    }
    return [pscustomobject]@{ Process = $game; VoiceOn = $voiceOn }
}

# === The window ===============================================================================
# join-roe-os.cmd without arguments (a double-click) or with --window. The functions above do the work;
# the ones below add only the window.

# The code both runspaces of the window load: this file's settings, constants and functions
# (without its main part), then Write-GuiHost and Read-GuiAnswer as Write-Host and Ask, so the
# console's output and questions go to the window.
function Get-JoinCode([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$(Split-Path -Leaf $Path) is damaged (line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)). Download it again." }
    $parts = @()
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst] -or $statement -is [Management.Automation.Language.AssignmentStatementAst]) { $parts += $statement.Extent.Text }
    }
    $parts += "function Write-Host {$(${function:Write-GuiHost})}"
    $parts += "function Ask {$(${function:Read-GuiAnswer})}"
    return $parts -join "`n"
}

# --- Between the worker and the window -------------------------------------------------------
# The worker never touches the window: it puts events into $sync.Events (line, ask, stats, game,
# done) and the window takes them out ten times a second.
function Send-GuiEvent([string]$Kind, $Data) { $sync.Events.Enqueue([pscustomobject]@{ Kind = $Kind; Data = $Data }) }
# Write-Host in the window: a line in the status, the details and the log (yellow and red ones as warnings).
function Write-GuiHost {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object, [object]$ForegroundColor, [object]$BackgroundColor, [switch]$NoNewline, [object]$Separator)
    $text = "$(@($Object) -join ' ')".Trim()
    if (-not $text) { return }
    $level = if ("$ForegroundColor" -in @('Red', 'Yellow')) { 'warn' } else { 'info' }
    Send-GuiEvent 'line' ([pscustomobject]@{ Text = $text; Level = $level })
}
# Ask in the window: a dialog, which the worker waits for. Cancel stops the step.
function Read-GuiAnswer {
    param([string]$Question, [string]$Default)
    $request = [pscustomobject]@{ Question = $Question; Default = $Default; Answer = $null; Cancelled = $false; Done = (New-Object Threading.ManualResetEventSlim $false) }
    Send-GuiEvent 'ask' $request
    $request.Done.Wait()
    if ($request.Cancelled) { throw 'Cancelled.' }
    $answer = "$($request.Answer)".Trim().Trim('"')
    if (-not $answer) { return $Default }
    return $answer
}
function Get-ErrorMessage($Record) {
    $exception = if ($Record -is [Management.Automation.ErrorRecord]) { $Record.Exception } else { $Record }
    while ($exception -is [Management.Automation.MethodInvocationException] -and $exception.InnerException) { $exception = $exception.InnerException }
    return "$($exception.Message)"
}
# Runs one piece of work in the worker and reports it (done: Ok, Result, Message, Details).
# Event: 'done' for the worker, 'side-done' for the side worker (the admin page).
function Invoke-Work([string]$Command, [hashtable]$Arguments, [string]$Event = 'done') {
    $done = [pscustomobject]@{ Ok = $true; Result = $null; Message = ''; Details = '' }
    try { $done.Result = & $Command @Arguments }
    catch { $done.Ok = $false; $done.Message = Get-ErrorMessage $_; $done.Details = "$($_ | Out-String)$($_.ScriptStackTrace)".Trim() }
    Send-GuiEvent $Event $done
}

# --- Work in the background --------------------------------------------------------------------
# The selected server: its name, version and who plays where; refreshes the names of its saved
# accounts (renamed in the game) and their roles (Roles: key -> admin, gm or player, ROLE).
function Invoke-ServerJob([string]$Server) {
    $ips = Resolve-ServerIps (Get-ServerHost $Server)
    $folder = Get-AccountFolder $Server
    $contact = Connect-Server $ips[0] $folder $ips $false
    $roles = @{}
    if ($contact.Info -match '^OK ' -and -not $contact.TooOld) {
        $accounts = Read-Accounts $folder
        if ($accounts.Count -and (Update-AccountNames $ips[0] $folder $accounts)) { Save-Accounts $folder $accounts | Out-Null }
        foreach ($a in @($accounts | Where-Object { $_.token })) {
            $role = ''
            try { $role = Get-AccountRole (Invoke-Account $ips[0] $folder "ROLE $($a.token)") } catch { }
            if ($role) { $roles[$a.token] = $role }
        }
    }
    return [pscustomobject]@{ Server = $Server; Contact = $contact; Roles = $roles }
}
# Advanced > Open the admin page: the login link of the account (Token) in the browser.
function Invoke-AdminJob([string]$Server, [string]$Token) {
    $hostName = Get-ServerHost $Server
    $ip = (Resolve-ServerIps $hostName)[0]
    $folder = Get-AccountFolder $Server
    $link = Request-AdminLink $ip $folder $hostName ([pscustomobject]@{ token = $Token })
    if ($link.Problem) { throw $link.Problem }
    Start-Process $link.Url
    return $link.Url
}
# A game folder as the window shows it: the Ring of Elysium folder (Base) and whether it is its
# XVersion folder (Dx12). A saved or picked XVersion folder is its parent with DirectX 12.
function Split-GameFolder([string]$Folder) {
    $trimmed = "$Folder".TrimEnd('\', '/')
    if ($trimmed -and [IO.Path]::GetFileName($trimmed) -eq 'XVersion') {
        $parent = Split-Path -Parent $trimmed
        if ($parent) { return [pscustomobject]@{ Base = $parent; Dx12 = $true } }
    }
    return [pscustomobject]@{ Base = $trimmed; Dx12 = $false }
}
# The folder the game starts from (Folder, '' when it has no Europa_Client.exe) and what is
# missing (Problem): the XVersion folder with DirectX 12, the folder itself without.
function Get-GameFolderChoice([string]$Base, [bool]$Dx12) {
    $result = [pscustomobject]@{ Folder = ''; Problem = '' }
    if (-not $Base) { $result.Problem = 'Choose the Ring of Elysium folder with Browse...'; return $result }
    $folder = if ($Dx12) { Join-Path $Base 'XVersion' } else { $Base }
    if (Test-Client $folder) { $result.Folder = $folder; return $result }
    if ($Dx12) {
        $result.Problem = "No DirectX 12 version found in ${Base} (no XVersion\Europa_Client.exe): uncheck DirectX 12."
    } elseif (Test-Client (Join-Path $Base 'XVersion')) {
        $result.Problem = "No DirectX 11 version found in ${Base} (no Europa_Client.exe): tick DirectX 12 to play its XVersion folder."
    } else {
        $result.Problem = "No Europa_Client.exe in ${Base}: choose the Ring of Elysium folder (usually C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium)."
    }
    return $result
}
# Whether the admin page's part shows for an account (Entry) of the server: only with GM rights
# there, as a GM or an admin (Roles from Invoke-ServerJob of that server).
function Test-ShowAdmin($Roles, $Entry) {
    return [bool]($Roles -and $Entry -and $Entry.token -and ($Roles[$Entry.token] -eq 'gm' -or $Roles[$Entry.token] -eq 'admin'))
}
# Play: the same steps as the console's main part, with the window's answers. Token and AccountName:
# the saved account (New: a new one); UseVoice false: no voice chat this time. Returns once the
# game has exited and the original voice DLL is back.
function Invoke-PlayJob([string]$Client, [string]$Server, [string]$Token, [string]$AccountName, [bool]$New, [bool]$UseVoice) {
    $settings = Read-Settings
    $client = Get-GameFolder $Client
    Confirm-GameFiles $client $false
    $hostName = Get-ServerHost $Server
    $firewall = $settings.firewall
    $voice = $settings.voice
    $voiceDll = $settings.voice_dll
    $serverList = Add-ServerUse @(Get-OfferedServers $settings) $Server
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
    $contact = Connect-Server $serverIp $folder $serverIps $true
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
        try { $stats = Get-ServerStats $serverIp $folder } catch { }
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
            try { $stats = Get-ServerStats $serverIp $folder } catch { }
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
    if ($Admin) { $lines += 'join-roe-os.cmd already runs as administrator: the details show the error.' }
    else { $lines += 'Right-click join-roe-os.cmd > Run as administrator (on a standard Windows account this needs an administrator''s password).' }
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
    <!-- The text next to a check box: only the box itself toggles it. -->
    <Style TargetType="TextBlock" x:Key="CheckLabel">
      <Setter Property="Margin" Value="5,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Foreground" Value="{x:Static SystemColors.GrayTextBrush}"/>
        </Trigger>
      </Style.Triggers>
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
      <CheckBox x:Name="Dx12Box" DockPanel.Dock="Right" Margin="8,0,2,0" VerticalAlignment="Center" Content="DirectX 12"/>
      <TextBox x:Name="GameBox" IsReadOnly="True" VerticalContentAlignment="Center"/>
    </DockPanel>
    <TextBlock x:Name="GameNote" Margin="0,4,0,0" TextWrapping="Wrap"/>
    <DockPanel Margin="0,14,0,0">
      <Button x:Name="VoiceButton" DockPanel.Dock="Right" Margin="6,0,0,0" Content="Choose folder..."/>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <CheckBox x:Name="VoiceBox" VerticalAlignment="Center" AutomationProperties.Name="Voice chat"/>
        <TextBlock x:Name="VoiceLabel" Style="{StaticResource CheckLabel}" FontWeight="Bold" Text="Voice chat"
                   IsEnabled="{Binding IsEnabled, ElementName=VoiceBox}"/>
      </StackPanel>
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
        <TextBlock Margin="0,6,0,0" TextWrapping="Wrap" Text="Account backup: one file with the keys of every account, to play with them on another PC (join-roe-os.cmd and join-roe-os.py read it too). Keep it private."/>
        <WrapPanel Margin="0,6,0,0">
          <Button x:Name="ExportButton" Margin="0,0,6,6" Content="Export accounts..."/>
          <Button x:Name="ImportButton" Margin="0,0,6,6" Content="Import accounts..."/>
          <Button x:Name="LogButton" Margin="0,0,6,6" Content="Open the log"/>
        </WrapPanel>
        <StackPanel x:Name="AdminPanel" Margin="0,6,0,0" Visibility="Collapsed">
          <TextBlock TextWrapping="Wrap" Text="This account is a GM on this server: the admin page has its settings (bots, matchmaking) and status, in your browser."/>
          <WrapPanel Margin="0,6,0,0">
            <Button x:Name="AdminButton" Margin="0,0,6,6" Content="Open the admin page"/>
          </WrapPanel>
        </StackPanel>
      </StackPanel>
    </Expander>
  </StackPanel>
</Window>
'@
}
function Get-GuiControlNames {
    return @('ServerBox', 'AddServerButton', 'ServerStats', 'AccountBox', 'GameBox', 'BrowseButton', 'Dx12Box', 'GameNote', 'VoiceBox', 'VoiceButton', 'VoiceNote',
        'PlayButton', 'StatusText', 'DetailsButton', 'DetailsBox', 'AdvancedBox', 'FirewallText', 'FirewallOnButton', 'FirewallOffButton', 'FirewallResetButton',
        'FirewallShowButton', 'ExportButton', 'ImportButton', 'LogButton', 'AdminPanel', 'AdminButton', 'VoiceLabel')
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
# The server line: one region per line, an offline one (Format-Stats) greyed.
function Set-StatsText($Control, [string]$Text, [string]$Level = 'info') {
    Set-Text $Control '' $Level
    $lines = @($Text -split "`n")
    for ($i = 0; $i -lt $lines.Count; ++$i) {
        if ($i) { $Control.Inlines.Add((New-Object Windows.Documents.LineBreak)) }
        $run = New-Object Windows.Documents.Run $lines[$i]
        if ($lines[$i] -match '\): offline\.?$') { $run.Foreground = Get-Brush 'muted' }
        $Control.Inlines.Add($run)
    }
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
# A question of the worker (join-roe-os.cmd's Ask): yes/no ones as a message box, others with a text field.
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
                'stats' { Set-StatsText $gui.C.ServerStats $item.Data }
                'game' {
                    $gui.GameRunning = $true
                    Update-Controls
                    Add-Line 'Game running. This window puts the original voice DLL back when the game exits.'
                }
                'done' { Complete-Work $item.Data }
                'side-done' { Complete-SideWork $item.Data }
            }
        }
    } catch {
        Show-GuiError $_
    } finally {
        $gui.Draining = $false
    }
}
# The worker: a runspace with join-roe-os.cmd and this file's functions, for one piece of work at a time.
function New-Worker([string]$Code) {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('sync', $sync)
    $worker = [powershell]::Create()
    $worker.Runspace = $runspace
    [void]$worker.AddScript($Code).Invoke()
    if ($worker.Streams.Error.Count) { throw "The background part could not load join-roe-os.cmd: $($worker.Streams.Error[0])" }
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
# Work next to the worker's (which waits for the game while it runs): the admin page. One at a
# time, in a second runspace made at its first use.
function Start-SideWork([string]$Command, [hashtable]$Arguments, [scriptblock]$OnDone) {
    if ($gui.SideJob) { return }
    if (-not $gui.SideWorker) { $gui.SideWorker = New-Worker $gui.Code }
    $gui.SideJob = $Command
    $gui.SideOnDone = $OnDone
    $gui.SideWorker.Commands.Clear()
    [void]$gui.SideWorker.AddCommand('Invoke-Work').AddParameter('Command', $Command).AddParameter('Arguments', $Arguments).AddParameter('Event', 'side-done')
    $gui.SideHandle = $gui.SideWorker.BeginInvoke()
    Update-Controls
}
function Complete-SideWork($Done) {
    try { [void]$gui.SideWorker.EndInvoke($gui.SideHandle) } catch { }
    $gui.SideWorker.Streams.ClearStreams()
    $onDone = $gui.SideOnDone
    $gui.SideJob = $null
    $gui.SideOnDone = $null
    if (-not $Done.Ok -and $Done.Details) { Write-GuiLog $Done.Details }
    try {
        if ($onDone) { & $onDone $Done } elseif (-not $Done.Ok) { Add-Line $Done.Message 'error' }
    } catch { Show-GuiError $_ }
    Update-Controls
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
    foreach ($name in @('ServerBox', 'AddServerButton', 'AccountBox', 'BrowseButton', 'Dx12Box', 'VoiceBox', 'VoiceButton', 'FirewallOnButton', 'FirewallOffButton',
            'FirewallResetButton', 'FirewallShowButton', 'ExportButton', 'ImportButton')) { $gui.C[$name].IsEnabled = -not $playing }
    # The admin page also while the game runs: it has a worker of its own (Start-SideWork).
    $gui.C.AdminButton.IsEnabled = -not $gui.SideJob
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
        $gui.Servers = @(Get-OfferedServers (Read-Settings))
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
    Update-AdminPanel
}
# The selected account's saved entry, or $null for "Create a new account".
function Get-SelectedAccount {
    $index = $gui.C.AccountBox.SelectedIndex
    if ($index -ge 0 -and $index -lt @($gui.Accounts).Count) { return $gui.Accounts[$index] }
    return $null
}
# The admin page's part under Advanced: there only for an account with GM rights on the selected server.
function Update-AdminPanel {
    $roles = if ($gui.RolesServer -and $gui.RolesServer -eq (Get-SelectedServer)) { $gui.Roles } else { $null }
    $gui.C.AdminPanel.Visibility = if (Test-ShowAdmin $roles (Get-SelectedAccount)) { 'Visible' } else { 'Collapsed' }
}
function Open-GuiAdmin {
    $server = Get-SelectedServer
    $entry = Get-SelectedAccount
    if (-not $server -or -not $entry -or -not $entry.token -or $gui.SideJob) { return }
    Add-Line "Opening the admin page for $($entry.name) ..."
    Start-SideWork 'Invoke-AdminJob' @{ Server = $server; Token = "$($entry.token)" } {
        param($done)
        if ($done.Ok) { Add-Line 'The admin page is open in your browser (its login link works once, for one minute).' } else { Add-Line "Could not open the admin page: $($done.Message)" 'error' }
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
    $gui.Roles = $Done.Result.Roles
    $gui.RolesServer = $server
    if ($contact.Name -and -not $gui.Playing) {
        $servers = @(Get-OfferedServers (Read-Settings))
        if (Set-ServerName $servers $server $contact.Name) { Update-Settings @{ servers = $servers }; Update-ServerList $server }
    }
    $line = Get-ServerInfoText $contact
    Set-StatsText $gui.C.ServerStats $line.Text $line.Level
    if (-not $gui.Playing) {
        $index = $gui.C.AccountBox.SelectedIndex
        Update-AccountList
        if ($index -lt $gui.C.AccountBox.Items.Count) { $gui.C.AccountBox.SelectedIndex = $index }
    }
    Update-AdminPanel
}
# The game folder: the Ring of Elysium folder (GameBase) and the DirectX 12 box (Dx12: its XVersion
# folder). Client is the resulting folder when it has Europa_Client.exe, else ''.
function Update-GameFolder {
    $gui.Updating = $true
    try { $gui.C.Dx12Box.IsChecked = [bool]$gui.Dx12 } finally { $gui.Updating = $false }
    $gui.C.GameBox.Text = $gui.GameBase
    $choice = Get-GameFolderChoice $gui.GameBase ([bool]$gui.Dx12)
    $gui.Client = $choice.Folder
    if (-not $gui.GameBase) {
        Set-Text $gui.C.GameNote ('Choose the Ring of Elysium folder with Browse...: usually C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium. ' +
            'Tick DirectX 12 for the DX12 version.') 'warn'
    } elseif ($choice.Problem) {
        Set-Text $gui.C.GameNote $choice.Problem 'warn'
    } else {
        Set-Text $gui.C.GameNote $(if ($gui.Dx12) { "The DirectX 12 version: $($choice.Folder)" } else { 'The DirectX 11 version.' }) 'muted'
    }
}
# Checks the game build of the chosen folder in the background and saves it (roe-join.json
# "client": the full folder, as join-roe-os.cmd keeps it).
function Save-GuiGameFolder {
    if (-not $gui.Client) { Add-Line (Get-GameFolderChoice $gui.GameBase ([bool]$gui.Dx12)).Problem 'error'; return }
    $folder = $gui.Client
    Add-Line "Checking the game in $folder ..."
    Start-Work 'Get-GameFolder' @{ Folder = $folder } {
        param($done)
        if (-not $done.Ok) { Add-Line $done.Message 'error'; return }
        $split = Split-GameFolder $done.Result
        $gui.GameBase = $split.Base
        $gui.Dx12 = $split.Dx12
        Update-Settings @{ client = $done.Result }
        Update-GameFolder
        Update-Voice
        Add-Line "Game folder: $($done.Result) (the tested version)."
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
        Set-Text $gui.C.VoiceNote ("Our $voiceFile is not next to join-roe-os.cmd or in its voice folder. Choose the folder that has it (the voice folder of the server package), " +
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
    $path = Select-Folder 'The Ring of Elysium folder (usually ...\steamapps\common\Ring of Elysium). Tick DirectX 12 for the DX12 version.' $gui.GameBase
    if (-not $path) { return }
    # An XVersion folder picked directly: the folder above it, with DirectX 12.
    $split = Split-GameFolder $path
    $gui.GameBase = $split.Base
    if ($split.Dx12) { $gui.Dx12 = $true }
    Update-GameFolder
    Save-GuiGameFolder
}
function Set-GuiDx12 {
    $gui.Dx12 = [bool]$gui.C.Dx12Box.IsChecked
    Update-GameFolder
    if ($gui.GameBase) { Save-GuiGameFolder }
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
    Update-Settings @{ servers = @(Add-ServerUse @(Get-OfferedServers (Read-Settings)) $address) }
    Update-ServerList $address
    Request-ServerInfo
}
function Start-Play {
    $server = Get-SelectedServer
    if (-not $server) { Add-Line 'Add the server first: Add server...' 'error'; return }
    if (-not (Test-Client $gui.Client)) {
        $problem = if ($gui.GameBase) { (Get-GameFolderChoice $gui.GameBase ([bool]$gui.Dx12)).Problem } else { '' }
        Add-Line $(if ($problem) { $problem } else { 'Choose the game folder first: Browse...' }) 'error'
        return
    }
    if ($null -eq (Read-Settings).firewall) {
        $answer = Show-Message ('join-roe-os.cmd can add Windows Firewall rules so the game reaches only the servers you join (it also tries the ' +
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
    $entry = Get-SelectedAccount
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
                if ($done.Ok) { Add-Line 'Firewall rules off: join-roe-os.cmd no longer sets them (the game can reach the internet).' } else { Add-Line $done.Message 'error' }
            }
        }
        'reset' {
            if ((Show-Message "Remove the firewall rules of every game folder (join-roe-os.cmd's and the server launcher's)? The next Play allows only its own server." 'YesNo' 'Question' 'No') -ne 'Yes') { return }
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
    Add-Line "Saved $($done.Accounts) accounts of $($done.Servers) servers in $($dialog.FileName). On the other PC: Import accounts... (or join-roe-os.cmd import <file>)."
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
    Write-GuiLog "join-roe-os.cmd $joinVersion opens its window ($env:ROE_JOIN_SELF)."
    $window = [Windows.Markup.XamlReader]::Parse((Get-GuiXaml))
    $gui.Window = $window
    $gui.C = @{}
    foreach ($name in (Get-GuiControlNames)) { $gui.C[$name] = $window.FindName($name) }
    $gui.Recent = New-Object Collections.ArrayList
    $gui.Queue = New-Object Collections.ArrayList
    $gui.Job = $null; $gui.Playing = $false; $gui.GameRunning = $false; $gui.Updating = $false; $gui.Draining = $false
    $gui.SideJob = $null; $gui.SideWorker = $null; $gui.Code = $Code
    $gui.Roles = $null; $gui.RolesServer = ''

    $gui.Worker = New-Worker $Code

    $settings = Read-Settings
    $saved = "$($settings.client)"
    if (-not (Test-Client $saved)) {
        $guess = 'C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium'
        $saved = if (Test-Client $guess) { $guess } else { '' }
    }
    $split = Split-GameFolder $saved
    $gui.GameBase = $split.Base
    $gui.Dx12 = $split.Dx12
    Update-GameFolder
    Update-ServerList ''
    Update-Voice
    Update-FirewallText
    Update-Controls
    Set-Text $gui.C.StatusText 'Choose the server and the account, then Play.' 'muted'

    Add-Handler $gui.C.ServerBox 'SelectionChanged' { if (-not $gui.Updating) { $gui.Roles = $null; $gui.RolesServer = ''; Update-AccountList; Request-ServerInfo } }
    Add-Handler $gui.C.AccountBox 'SelectionChanged' { if (-not $gui.Updating) { Update-AdminPanel } }
    Add-Handler $gui.C.AdminButton 'Click' { Open-GuiAdmin }
    Add-Handler $gui.C.AddServerButton 'Click' { Add-GuiServer }
    Add-Handler $gui.C.BrowseButton 'Click' { Select-GameFolder }
    Add-Handler $gui.C.Dx12Box 'Click' { if (-not $gui.Updating) { Set-GuiDx12 } }
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
        $answer = Show-Message ("join-roe-os.cmd is still joining or waits for the game to exit, to put the game's original $voiceFile back. " +
            'Close it anyway? Then the next start of join-roe-os.cmd puts it back.') 'YesNo' 'Warning' 'No'
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
    Write-GuiLog 'join-roe-os.cmd closed its window.'
}

# === Main part ================================================================================
if ($FirewallStep) { exit (Invoke-FirewallStep $FirewallStep) }
# join-roe-os.ps1 of the separate files started on its own (Run with PowerShell): as by its join-roe-os.cmd.
if (-not $env:ROE_JOIN_SELF -and (Split-Path -Leaf "$PSCommandPath") -eq 'join-roe-os.ps1') {
    $env:ROE_JOIN_CODE = $PSCommandPath
    $env:ROE_JOIN_SELF = Join-Path (Split-Path -Parent $PSCommandPath) 'join-roe-os.cmd'
}
# The .ps1 copies the batch part writes (run-*.ps1), once PowerShell has read them.
Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'roe-join') -Filter 'run-*.ps1' -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-10) } | Remove-Item -ErrorAction SilentlyContinue
# The window (ROE_JOIN_WINDOW from the batch part: no arguments, or --window).
if ($env:ROE_JOIN_WINDOW) {
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
        if (-not $env:ROE_JOIN_SELF) { throw 'Start join-roe-os.cmd by double-clicking it.' }
        $sync = [hashtable]::Synchronized(@{ Events = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]' })
        $gui = @{}
        $joinCode = Get-JoinCode (Get-JoinCodePath)
        # This thread has the functions already; only Write-Host and Ask become the window's.
        Set-Item -Path function:Write-Host -Value ${function:Write-GuiHost}
        Set-Item -Path function:Ask -Value ${function:Read-GuiAnswer}
        Start-Gui $joinCode
    } catch {
        $message = Get-ErrorMessage $_
        Write-GuiLog "join-roe-os.cmd could not start its window: $message`r`n$($_ | Out-String)$($_.ScriptStackTrace)"
        try { [void][Windows.MessageBox]::Show("join-roe-os.cmd could not start its window: $message`n`nDetails: $(Get-GuiLogPath)", 'Ring of Elysium 2022', 'OK', 'Error') } catch { }
    }
    [Environment]::Exit(0)
}

# The console.
$failed = 'Could not join: '
try {
    $settings = Read-Settings
    # --console: this console even without other arguments (the batch part takes --window).
    $argText = ("$env:ROE_JOIN_ARGS" -replace '(^|\s)--console(?=\s|$)', ' ').Trim()
    # --skip-file-check: no check of the game files (for players who changed them on purpose).
    $skipFileCheck = $argText -match '(^|\s)--skip-file-check(?=\s|$)'
    $argText = ($argText -replace '(^|\s)--skip-file-check(?=\s|$)', ' ').Trim()
    $usage = ('Usage: join-roe-os.cmd [--console] [--skip-file-check] [-Server <address>] [-Name <name>] | firewall [on|off|reset] | voice [on|off] | export [FILE] | import FILE' + "`n" +
        'For GM accounts: join-roe-os.cmd [-Server <address>] [-Name <name>] admin (opens the server''s admin page)' + "`n" +
        'The window: join-roe-os.cmd without arguments, or join-roe-os.cmd --window')
    $arguments = Read-Arguments $argText
    # Ours left by a crash or a closed window: the original back first. Not for "admin", which
    # runs next to a game this script started (its join puts the DLL back when the game exits).
    if ($arguments.Command -ne 'admin') { Restore-AllVoice }
    $command = $arguments.Command
    $givenName = $arguments.Name
    $givenServer = $arguments.Server
    if ($argText -match '(^|\s)-Name(\s|$)' -and (-not $givenName -or $givenName.Length -gt 24 -or $givenName -match '[\x00-\x1f]')) {
        throw 'The name must be 1 to 24 characters without control characters.'
    }
    if ($command -and $command -ne 'admin' -and ($givenName -or $givenServer)) { throw $usage }
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
        Write-Host "Voice chat: $state. Our ${voiceFile}: $dll ($found). Commands: join-roe-os.cmd voice on | off (on also asks for the DLL)"
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
            Write-Host 'On the other computer: join-roe-os.cmd import <file> (or python3 join-roe-os.py --import <file>).'
            exit 0
        }
        if (-not $file) { throw 'Usage: join-roe-os.cmd import FILE' }
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
    if ($command -eq 'admin') {
        # The admin page (GM accounts): the server and the account as for a join, then the browser.
        $failed = 'Could not open the admin page: '
        $serverList = @(Get-OfferedServers $settings)
        $server = "$(Select-Server $serverList $givenServer)".Trim()
        if (-not $server) { throw 'A server address is needed.' }
        $hostName = Get-ServerHost $server
        $serverIp = (Resolve-ServerIps $hostName)[0]
        $folder = Get-AccountFolder $server
        $keyed = New-Object Collections.ArrayList
        foreach ($a in (Read-Accounts $folder)) { if ($a.token) { [void]$keyed.Add($a) } }
        if (-not $keyed.Count) { throw 'No saved account of this server. Join it once with your GM account first.' }
        $entry = Select-Account $keyed $givenName
        if (-not $entry) { throw $(if ($givenName) { "No saved account named $givenName for this server." } else { 'Choose a saved account: the admin page is for existing GM accounts.' }) }
        $link = Request-AdminLink $serverIp $folder $hostName $entry
        if ($link.Problem) { throw $link.Problem }
        Write-Host "Opening the admin page for $($entry.name) in your browser (the link works once, for one minute)."
        Start-Process $link.Url
        exit 0
    }
    if ($command) {
        if ($command -notmatch '^firewall(\s+(on|off|reset|status))?$') { throw $usage }
        $action = if ($Matches[2]) { $Matches[2].ToLowerInvariant() } else { 'status' }
        $client = $settings.client
        if ($action -eq 'status') { Show-Firewall $client $settings.firewall; exit 0 }
        if ($action -eq 'reset') { Reset-AllRules; exit 0 }
        $settings | Add-Member -NotePropertyName firewall -NotePropertyValue ($action -eq 'on') -Force
        $settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        if ($action -eq 'on') { Write-Host 'Firewall rules on: the next join creates them.'; exit 0 }
        Remove-FolderRules $client
        Write-Host 'Firewall rules off: join-roe-os.cmd no longer creates them (the game can reach the internet).'
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
    Confirm-GameFiles $client $skipFileCheck

    # 2. Server and name.
    $serverList = @(Get-OfferedServers $settings)
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
        Write-Host 'join-roe-os.cmd can add Windows Firewall rules so the game reaches only the servers you join'
        Write-Host '(it also tries the publisher''s old servers). That needs administrator approval when the allowed addresses change.'
        $firewall = (Ask 'Add the firewall rules? (y/n)' 'y') -match '^[yY]'
        Save-Settings
        Write-Host 'Change it later with: join-roe-os.cmd firewall on | off | reset'
    }
    $rules = Update-Firewall $client $serverList $server $serverIps $contact.Listed $firewall
    if ($rules.Check) { Confirm-FirewallState $client $rules.Programs $rules.Check.Wanted $rules.Check.RulesOn $rules.Check.Step }
    Save-Settings

    # 4. Log in.
    $accountList = Read-Accounts $folder
    if ($accountList.Count -and -not $givenName -and (Update-AccountNames $serverIp $folder $accountList)) { Save-Accounts $folder $accountList | Out-Null }
    $entry = Select-Account $accountList $givenName
    $login = Connect-Account $serverIp $folder $accountList $entry $givenName
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
    Write-Host ($failed + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
