<#
Straiker — Azure AI Foundry scanner onboarding

WHAT THIS DOES
  1. Creates (or reuses) an Entra app registration + service principal for the
     Straiker scanner, and a client secret.
  2. Enumerates the estate: subscriptions -> AI Foundry accounts -> projects.
  3. Assigns every role the scanner needs, at every scope it needs them.
  4. VERIFIES with the service principal's OWN credentials that each project is
     actually readable — calling the same API the scanner calls.
  5. Prints a per-subscription / per-account / per-project report and writes it
     to a JSON file you can send to Straiker.

WHY VERIFICATION MATTERS
  A role assignment succeeding is not the same as access working. Azure RBAC
  takes 30s-5min to propagate, some projects sit behind a virtual network that
  no role grant can reach, and the data-plane call the scanner makes is not the
  one a control-plane role implies. So this script assigns first, then polls the
  data plane until it either works or the deadline passes, and reports each
  project individually.

  Verification calls GET /agents — the exact call the scanner makes. Checking a
  different endpoint can report success on an estate the scanner cannot read.

PREREQUISITES
  * Az PowerShell module:  Install-Module -Name Az -Scope CurrentUser -Force
  * Signed in:             Connect-AzAccount   (add -TenantId for multi-tenant)
  * Owner or User Access Administrator on each subscription you onboard.
    Anything less cannot create role assignments.

ROLES ASSIGNED
  Reader             @ each subscription   ARM discovery: subscriptions,
                                           Foundry accounts, projects,
                                           App Insights components
  Monitoring Reader  @ each subscription   App Insights KQL — required for agent
                                           conversations
  Foundry User       @ each subscription   Foundry data plane, inherited
                     @ each project        Foundry data plane, explicit. Granted
                                           at both scopes on purpose: the project
                                           grant takes effect quickly and makes
                                           verification meaningful, the
                                           subscription grant is the safety net
                                           if a project grant fails.

USAGE
  .\azure-foundry-onboarding-setup-powershell.ps1
  .\azure-foundry-onboarding-setup-powershell.ps1 -SubscriptionIds sub1,sub2
  .\azure-foundry-onboarding-setup-powershell.ps1 -VerifyOnly
#>

#Requires -Modules Az.Accounts, Az.Resources

[CmdletBinding()]
param(
    # Subscriptions to onboard. Omit to be shown what you can see and asked.
    [string[]] $SubscriptionIds,

    # Entra app registration name. Reused if it already exists.
    [string]   $AppName = 'straiker-foundry-scanner',

    # Assign nothing; only enumerate and verify. Requires -ClientId/-ClientSecret
    # since no new credential is created.
    [switch]   $VerifyOnly,
    [string]   $ClientId,
    [string]   $ClientSecret,

    # How long to keep retrying projects that have not propagated yet.
    [int]      $VerifyTimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'

$Arm               = 'https://management.azure.com'
$AccountsApi       = '2023-05-01'
$ProjectsApi       = '2025-04-01-preview'   # accounts/projects child resource
$RoleApi           = '2022-04-01'
# Assign by GUID, not name: this role was renamed from "Azure AI User" and the
# name is not consistent across tenants during the rollout.
$FoundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

# ── Output helpers ────────────────────────────────────────────────────────────

function Write-Head { param([string]$Text) Write-Host ''; Write-Host $Text; Write-Host ('─' * 74) }

function Write-Row {
    param([string]$Status, [string]$Text, [string]$Detail = '')
    $colour = switch ($Status) {
        'OK'       { 'Green' }   'EXISTS'  { 'DarkGray' } 'PENDING' { 'Yellow' }
        'DENIED'   { 'Red' }     'BLOCKED' { 'Magenta' }  'SKIP'    { 'DarkGray' }
        default    { 'Gray' }
    }
    Write-Host ("  [{0,-7}] {1}" -f $Status, $Text) -ForegroundColor $colour
    if ($Detail) { Write-Host ("            {0}" -f $Detail) -ForegroundColor DarkGray }
}

# ── HTTP helpers ──────────────────────────────────────────────────────────────

# ARM GET that follows nextLink, using YOUR Az login. Returns all items.
function Invoke-ArmList {
    param([string] $Url)
    $items = @()
    while ($Url) {
        $resp = Invoke-AzRestMethod -Method GET -Uri $Url
        if ($resp.StatusCode -ne 200) {
            return @{ Ok = $false; StatusCode = $resp.StatusCode; Items = @() }
        }
        $page = $resp.Content | ConvertFrom-Json
        if ($page.value) { $items += $page.value }
        $Url = $page.nextLink
    }
    return @{ Ok = $true; StatusCode = 200; Items = $items }
}

# Client-credentials token for the SP, so every check below sees exactly what the
# Straiker scanner will see rather than what your admin login can see.
function Get-SpToken {
    param([string] $Scope)
    try {
        (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            client_id     = $AppId
            client_secret = $SpSecret
            grant_type    = 'client_credentials'
            scope         = $Scope
        }).access_token
    } catch { $null }
}

# Pulls status code and error text out of a failed Invoke-RestMethod, across PS 5
# and 7.
#
# Azure puts the useful text in a different place depending on host and error:
# PowerShell 7 fills ErrorDetails.Message, PowerShell 5 needs the response stream
# read manually, and some failures carry it only on the exception message. All
# three are gathered and concatenated, because the classification below matches on
# wording — losing the text downgrades a firewall block to "transient", which is
# the one mistake this whole function exists to prevent.
function Get-HttpFailure {
    param($ErrorRecord)
    $status = 0
    $parts  = @()

    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode.value__ } catch { }

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $parts += $ErrorRecord.ErrorDetails.Message
    }
    try {
        $stream = $ErrorRecord.Exception.Response.GetResponseStream()
        if ($stream) { $parts += [System.IO.StreamReader]::new($stream).ReadToEnd() }
    } catch { }
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        $parts += $ErrorRecord.Exception.Message
    }

    $body = ($parts | Where-Object { $_ }) -join ' '

    # Some hosts surface the code only in the text; recover it so the status-based
    # branches below still fire.
    if ($status -eq 0 -and $body -match '\b(403|404|429)\b') { $status = [int]$Matches[1] }

    return @{ Status = $status; Body = $body }
}

# Turns a data-plane failure into an actionable classification. The distinction
# between a missing role and a network block matters: only the first is fixable
# by this script, and telling a firewalled customer to "wait for propagation"
# sends them down a road that never ends.
function Get-FailureKind {
    param([int] $Status, [string] $Body)

    if ($Body -match 'Virtual Network|Firewall|Public access is disabled|private endpoint') {
        return @{ Kind = 'BLOCKED'; Reason = 'network rules block access (virtual network / firewall / private endpoint)' }
    }
    if ($Status -eq 403 -and $Body -match 'does not have permissions|AuthorizationFailed|agents/read') {
        return @{ Kind = 'DENIED';  Reason = 'role not effective yet — or not assigned' }
    }
    if ($Status -eq 403) { return @{ Kind = 'DENIED';  Reason = 'access denied (403)' } }
    if ($Status -eq 404) { return @{ Kind = 'DENIED';  Reason = 'project or agents API not found (404)' } }
    if ($Status -eq 0)   { return @{ Kind = 'PENDING'; Reason = 'no response — network or transient error' } }
    return @{ Kind = 'PENDING'; Reason = "HTTP $Status" }
}

# ── Role assignment ───────────────────────────────────────────────────────────

$GuidRegex = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

function Assign-Role {
    param([string] $Role, [string] $Scope, [string] $Label, [string] $Display)

    if (-not $Display) { $Display = $Role }
    $params = @{ ObjectId = $SpObjectId; Scope = $Scope; ErrorAction = 'Stop' }
    if ($Role -match $GuidRegex) { $params.RoleDefinitionId = $Role } else { $params.RoleDefinitionName = $Role }

    # ARM writes are throttled; a large estate can make hundreds of them.
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            New-AzRoleAssignment @params | Out-Null
            Write-Row 'OK' "$Display @ $Label"
            return @{ Ok = $true; Status = 'assigned' }
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'RoleAssignmentExists|already exists') {
                Write-Row 'EXISTS' "$Display @ $Label"
                return @{ Ok = $true; Status = 'already_assigned' }
            }
            if ($msg -match 'AuthorizationFailed|does not have authorization') {
                Write-Row 'DENIED' "$Display @ $Label" 'you need Owner or User Access Administrator at this scope'
                return @{ Ok = $false; Status = 'assign_denied'; Error = $msg }
            }
            if ($msg -match 'TooManyRequests|429|throttl' -and $attempt -lt 4) {
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }
            Write-Row 'DENIED' "$Display @ $Label" $msg
            return @{ Ok = $false; Status = 'assign_failed'; Error = $msg }
        }
    }
    return @{ Ok = $false; Status = 'assign_failed'; Error = 'exhausted retries' }
}

# ── Step 0: session ───────────────────────────────────────────────────────────

$ctx = Get-AzContext
if (-not $ctx) { Write-Host 'ERROR: not signed in. Run: Connect-AzAccount'; exit 1 }
$TenantId = $ctx.Tenant.Id

Write-Host 'Straiker — Azure AI Foundry onboarding'
Write-Host "Tenant: $TenantId"

# ── Step 1: choose subscriptions ──────────────────────────────────────────────

if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    Write-Head 'Subscriptions you can see in this tenant'
    $visible = @(Get-AzSubscription -TenantId $TenantId | Where-Object { $_.State -eq 'Enabled' })
    foreach ($s in $visible) { Write-Host "    $($s.Id)  ($($s.Name))" }

    $raw = Read-Host 'Subscription IDs to onboard (comma-separated, or Enter for ALL of the above)'
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $SubscriptionIds = @($visible | ForEach-Object { $_.Id })
    } else {
        $SubscriptionIds = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}
if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    Write-Host 'ERROR: no subscriptions selected.'; exit 1
}
Write-Host ''
Write-Host "Onboarding $($SubscriptionIds.Count) subscription(s)."

# ── Step 2: app registration, service principal, secret ───────────────────────

if ($VerifyOnly) {
    if (-not $ClientId -or -not $ClientSecret) {
        Write-Host 'ERROR: -VerifyOnly needs -ClientId and -ClientSecret (no new credential is created).'
        exit 1
    }
    $AppId    = $ClientId
    $SpSecret = $ClientSecret
    $sp       = Get-AzADServicePrincipal -ApplicationId $AppId -ErrorAction SilentlyContinue
    if (-not $sp) { Write-Host "ERROR: no service principal for client id $AppId in tenant $TenantId."; exit 1 }
    $SpObjectId = $sp.Id
    Write-Head 'Verify only — no roles will be assigned'
    Write-Host "  app id:    $AppId"
    Write-Host "  object id: $SpObjectId"
} else {
    Write-Head 'Service principal'
    $existing = Get-AzADApplication -DisplayName $AppName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        $AppId = $existing.AppId
        Write-Row 'EXISTS' "app registration '$AppName' ($AppId)"
        $sp = Get-AzADServicePrincipal -ApplicationId $AppId -ErrorAction SilentlyContinue
        if (-not $sp) {
            $sp = New-AzADServicePrincipal -ApplicationId $AppId
            Start-Sleep -Seconds 15
        }
    } else {
        $app = New-AzADApplication -DisplayName $AppName
        $AppId = $app.AppId
        $sp = New-AzADServicePrincipal -ApplicationId $AppId
        Start-Sleep -Seconds 15   # Entra replication
        Write-Row 'OK' "app registration '$AppName' created ($AppId)"
    }
    $SpObjectId = $sp.Id
    Write-Host "            object id: $SpObjectId  (this is the id that appears in Straiker's errors)"

    $cred     = New-AzADAppCredential -ApplicationId $AppId -EndDate (Get-Date).AddYears(2)
    $SpSecret = $cred.SecretText
    Write-Row 'OK' 'client secret created (valid 2 years)'
}

# ── Step 3: enumerate the estate ──────────────────────────────────────────────
# Done with YOUR login, so the inventory is complete even where the SP has no
# access yet. That is the point: we want to report what exists, then separately
# report what the SP can actually read.

Write-Head 'Estate'
$estate = @()   # one entry per subscription

foreach ($sub in $SubscriptionIds) {
    $subEntry = @{ subscription_id = $sub; name = ''; accounts = @(); error = '' }
    try { $subEntry.name = (Get-AzSubscription -SubscriptionId $sub -TenantId $TenantId).Name } catch { }

    $accResult = Invoke-ArmList "$Arm/subscriptions/$sub/providers/Microsoft.CognitiveServices/accounts?api-version=$AccountsApi"
    if (-not $accResult.Ok) {
        $subEntry.error = "cannot list Cognitive Services accounts (HTTP $($accResult.StatusCode))"
        Write-Row 'SKIP' "subscription/$sub" $subEntry.error
        $estate += $subEntry
        continue
    }

    # A Foundry account is one exposing a *.services.ai.azure.com endpoint — the
    # same rule the Straiker scanner applies. Others are reported as skipped
    # rather than silently dropped.
    foreach ($acc in $accResult.Items) {
        $endpoints = ''
        if ($acc.properties.endpoints) { $endpoints = ($acc.properties.endpoints.PSObject.Properties.Value -join ' ') }
        if ($endpoints -notmatch '\.services\.ai\.azure\.com') {
            Write-Row 'SKIP' "$($acc.name)" 'not an AI Foundry account (no services.ai.azure.com endpoint)'
            $subEntry.accounts += @{ name = $acc.name; id = $acc.id; foundry = $false; projects = @()
                                     skip_reason = 'not an AI Foundry account (no services.ai.azure.com endpoint)' }
            continue
        }

        $accEntry = @{ name = $acc.name; id = $acc.id; foundry = $true; projects = @(); error = '' }
        $projResult = Invoke-ArmList "$Arm$($acc.id)/projects?api-version=$ProjectsApi"
        if (-not $projResult.Ok) {
            $accEntry.error = "cannot list projects (HTTP $($projResult.StatusCode))"
            Write-Row 'SKIP' "$($acc.name)" $accEntry.error
            $subEntry.accounts += $accEntry
            continue
        }
        foreach ($proj in $projResult.Items) {
            # ARM returns child names as "account/project"; keep the leaf.
            $leaf = ($proj.name -split '/')[-1]
            $accEntry.projects += @{ name = $leaf; scope = "$($acc.id)/projects/$leaf"; status = 'unknown'; reason = '' }
        }
        Write-Row 'OK' "$($acc.name) — $($accEntry.projects.Count) project(s)"
        $subEntry.accounts += $accEntry
    }

    $estate += $subEntry
}

$foundryAccounts = @($estate.accounts | Where-Object { $_.foundry })
$allProjects     = @($foundryAccounts.projects)
Write-Host ''
Write-Host "Found $($SubscriptionIds.Count) subscription(s), $($foundryAccounts.Count) Foundry account(s), $($allProjects.Count) project(s)."
if ($allProjects.Count -eq 0) {
    Write-Host 'WARNING: no Foundry projects found. Check the subscriptions contain AI Foundry accounts.'
}

# ── Step 4: assign every role, everywhere, in one pass ────────────────────────
# Assign first and verify later, deliberately. Verifying each project right after
# assigning it would pay the propagation wait once per project; assigning
# everything first lets all of them propagate concurrently.

if (-not $VerifyOnly) {
    Write-Head 'Assigning roles'
    foreach ($sub in $estate) {
        $subScope = "/subscriptions/$($sub.subscription_id)"
        foreach ($role in @(@{ r = 'Reader'; d = 'Reader' },
                            @{ r = 'Monitoring Reader'; d = 'Monitoring Reader' },
                            @{ r = $FoundryUserRoleId; d = 'Foundry User' })) {
            $res = Assign-Role -Role $role.r -Scope $subScope -Label "subscription/$($sub.subscription_id)" -Display $role.d
            if (-not $res.Ok -and $role.d -eq 'Reader') {
                Write-Host '            Reader is required for discovery — later checks on this subscription will fail.'
            }
        }

        foreach ($acc in ($sub.accounts | Where-Object { $_.foundry })) {
            foreach ($proj in $acc.projects) {
                $res = Assign-Role -Role $FoundryUserRoleId -Scope $proj.scope -Label "$($acc.name)/$($proj.name)" -Display 'Foundry User'
                $proj.status = if ($res.Ok) { 'assigned' } else { 'assign_failed' }
                $proj.reason = if ($res.Ok) { '' } else { $res.Error }
            }
        }
    }
}

# ── Step 5: verify as the service principal, in waves ─────────────────────────
# Each wave retries only what has not succeeded, so total time is the longest
# propagation rather than the sum of them. Network-blocked projects are taken out
# of the retry set immediately — no role grant will ever fix those.

Write-Head 'Verifying with the service principal'

$ArmToken = $null
for ($i = 0; $i -lt 6 -and -not $ArmToken; $i++) {
    $ArmToken = Get-SpToken "$Arm/.default"
    if (-not $ArmToken) { Write-Host '  waiting for the credential to become usable...'; Start-Sleep -Seconds 10 }
}
if (-not $ArmToken) {
    Write-Host 'ERROR: the service principal could not obtain a token. Check the client id and secret.'
    exit 1
}

$FoundryToken = Get-SpToken 'https://ai.azure.com/.default'
if (-not $FoundryToken) {
    Write-Host 'ERROR: the service principal could not obtain a Foundry data-plane token.'
    exit 1
}

# Subscription-level reads, as the SP.
foreach ($sub in $estate) {
    try {
        $r = Invoke-RestMethod -Uri "$Arm/subscriptions/$($sub.subscription_id)/providers/Microsoft.CognitiveServices/accounts?api-version=$AccountsApi" `
                               -Headers @{ Authorization = "Bearer $ArmToken" }
        $sub.sp_accounts_visible = @($r.value).Count
        Write-Row 'OK' "subscription/$($sub.subscription_id) — SP can list accounts ($($sub.sp_accounts_visible))"
    } catch {
        $f = Get-HttpFailure $_
        $sub.sp_accounts_visible = 0
        $sub.error = "SP cannot list accounts (HTTP $($f.Status))"
        Write-Row 'DENIED' "subscription/$($sub.subscription_id) — SP cannot list accounts" 'Reader missing or not yet propagated'
    }
}

# Per-project data-plane verification, in waves.
$pending  = [System.Collections.Generic.List[object]]::new()
foreach ($sub in $estate) {
    foreach ($acc in ($sub.accounts | Where-Object { $_.foundry })) {
        foreach ($proj in $acc.projects) { $pending.Add(@{ Account = $acc.name; Project = $proj }) }
    }
}

$deadline = (Get-Date).AddMinutes($VerifyTimeoutMinutes)
$wave     = 0
while ($pending.Count -gt 0) {
    $wave++
    $stillPending = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $pending) {
        $acct = $item.Account; $proj = $item.Project
        $url  = "https://$acct.services.ai.azure.com/api/projects/$($proj.name)/agents?api-version=v1"
        try {
            # GET /agents is what the Straiker scanner calls. Verifying anything
            # else can report success on an estate the scanner cannot read.
            Invoke-RestMethod -Method GET -Uri $url -Headers @{ Authorization = "Bearer $FoundryToken" } | Out-Null
            $proj.status = 'ok'; $proj.reason = ''
            Write-Row 'OK' "$acct/$($proj.name) — agents readable"
        } catch {
            $f    = Get-HttpFailure $_
            $kind = Get-FailureKind -Status $f.Status -Body $f.Body
            $proj.status = $kind.Kind.ToLower(); $proj.reason = $kind.Reason
            if ($kind.Kind -eq 'BLOCKED') {
                Write-Row 'BLOCKED' "$acct/$($proj.name)" $kind.Reason
            } elseif ((Get-Date) -lt $deadline) {
                $stillPending.Add($item)
            } else {
                Write-Row 'DENIED' "$acct/$($proj.name)" $kind.Reason
            }
        }
    }

    $pending = $stillPending
    if ($pending.Count -eq 0) { break }
    if ((Get-Date) -ge $deadline) {
        foreach ($item in $pending) {
            $item.Project.status = 'pending'
            $item.Project.reason = 'not readable within the verification window; Straiker re-checks every scan'
            Write-Row 'PENDING' "$($item.Account)/$($item.Project.name)" $item.Project.reason
        }
        break
    }
    Write-Host "  wave $wave — $($pending.Count) project(s) not readable yet, retrying in 30s (role propagation takes 30s-5min)..."
    Start-Sleep -Seconds 30
}

# App Insights, best effort: conversations need Monitoring Reader plus a linked
# component. Reported, never fatal.
$AiToken = Get-SpToken 'https://api.applicationinsights.io/.default'
$AiAppId = ''
foreach ($sub in $estate) {
    if ($AiAppId) { break }
    try {
        $c = Invoke-RestMethod -Uri "$Arm/subscriptions/$($sub.subscription_id)/providers/microsoft.insights/components?api-version=2020-02-02" `
                               -Headers @{ Authorization = "Bearer $ArmToken" }
        if (@($c.value).Count -gt 0) { $AiAppId = $c.value[0].properties.AppId }
    } catch { }
}
if (-not $AiAppId) {
    Write-Row 'SKIP' 'App Insights' 'no component found in scope — agent conversations will not be collected'
} elseif ($AiToken) {
    try {
        Invoke-RestMethod -Method Post -Uri "https://api.applicationinsights.io/v1/apps/$AiAppId/query" `
            -Headers @{ Authorization = "Bearer $AiToken"; 'Content-Type' = 'application/json' } `
            -Body '{"query":"dependencies | limit 1","timespan":"PT1H"}' | Out-Null
        Write-Row 'OK' 'App Insights KQL query (Monitoring Reader)'
    } catch {
        Write-Row 'DENIED' 'App Insights KQL query' 'Monitoring Reader missing or not yet propagated'
    }
} else {
    Write-Row 'DENIED' 'App Insights token' 'could not obtain an App Insights token'
}

# ── Step 6: report ────────────────────────────────────────────────────────────

$flat = @()
foreach ($sub in $estate) {
    foreach ($acc in ($sub.accounts | Where-Object { $_.foundry })) {
        foreach ($proj in $acc.projects) {
            $flat += [pscustomobject]@{
                Subscription = $sub.subscription_id
                Account      = $acc.name
                Project      = $proj.name
                Status       = $proj.status
                Reason       = $proj.reason
            }
        }
    }
}

# Rendered as a tree rather than a table: a table truncates the reason column,
# and the reason is the only part a customer can act on. Everything the script
# saw is listed here — including accounts it skipped — so this console output is
# the complete record, copy-pasteable into a ticket.
Write-Head 'Result — every subscription, account and project'
foreach ($sub in $estate) {
    $subName = if ($sub.name) { " ($($sub.name))" } else { '' }
    Write-Host ''
    Write-Host "  subscription $($sub.subscription_id)$subName"
    if ($sub.error) { Write-Host "      ! $($sub.error)" -ForegroundColor Red }

    if ($sub.accounts.Count -eq 0) {
        Write-Host '      (no Cognitive Services accounts)' -ForegroundColor DarkGray
        continue
    }

    foreach ($acc in $sub.accounts) {
        if (-not $acc.foundry) {
            Write-Host "      account $($acc.name) — skipped: $($acc.skip_reason)" -ForegroundColor DarkGray
            continue
        }
        Write-Host "      account $($acc.name)"
        if ($acc.error) { Write-Host "          ! $($acc.error)" -ForegroundColor Red }
        if ($acc.projects.Count -eq 0) {
            Write-Host '          (no projects)' -ForegroundColor DarkGray
            continue
        }
        foreach ($proj in $acc.projects) {
            $tag = $proj.status.ToUpper()
            $colour = switch ($proj.status) {
                'ok'      { 'Green' }  'pending' { 'Yellow' }
                'blocked' { 'Magenta' } default  { 'Red' }
            }
            $line = "          [{0,-7}] {1}" -f $tag, $proj.name
            if ($proj.reason) { $line += " — $($proj.reason)" }
            Write-Host $line -ForegroundColor $colour
        }
    }
}
if ($flat.Count -eq 0) {
    Write-Host ''
    Write-Host '  (no Foundry projects were found in the selected subscriptions)'
}

$okCount      = @($flat | Where-Object Status -eq 'ok').Count
$blockedCount = @($flat | Where-Object Status -eq 'blocked').Count
$deniedCount  = @($flat | Where-Object Status -eq 'denied').Count
$pendingCount = @($flat | Where-Object Status -eq 'pending').Count

Write-Head 'Summary'
Write-Host "  readable now      $okCount"
Write-Host "  pending           $pendingCount   (should resolve on its own; Straiker re-checks every scan)"
Write-Host "  denied            $deniedCount"
Write-Host "  network blocked   $blockedCount"

if ($blockedCount -gt 0) {
    Write-Host ''
    Write-Host '  Network-blocked projects need Straiker''s access allowlisted on the resource,'
    Write-Host '  or a private endpoint. A role assignment cannot reach them.'
}
if ($deniedCount -gt 0) {
    Write-Host ''
    Write-Host '  Denied projects: confirm you hold Owner or User Access Administrator on the'
    Write-Host '  subscription, then re-run this script.'
}

Write-Host ''
Write-Host '  Please copy this output and send it to Straiker — it is the record of'
Write-Host '  what was found and what is reachable.'

if (-not $VerifyOnly) {
    Write-Head 'Paste these values into Straiker'
    Write-Host "  Tenant ID:        $TenantId"
    Write-Host "  Subscription IDs: $($SubscriptionIds -join ',')"
    Write-Host "  Client ID:        $AppId"
    Write-Host "  Client Secret:    $SpSecret"
    Write-Host ''
    Write-Host '  The secret is shown once. Copy it now.'
}

# Denied is actionable and should fail automation; pending is expected and should not.
if ($deniedCount -gt 0) { exit 1 }
exit 0
