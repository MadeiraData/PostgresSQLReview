<#
.SYNOPSIS
    PostgreSQL Review Report Generator.

.DESCRIPTION
    Reads all *.json files located in the same folder as this script (or in
    -InputFolder). Each JSON file holds the PostgreSQL review results for one
    database; the file name (without extension) is treated as the database name.

    The review JSON is produced by a SQL export that concatenates fixed-width
    string fragments, so every physical line is space-padded and ends with a
    literal '+' concatenation marker. The loader strips that marker before
    parsing.

    Each file's root object contains:
      - Summary (counts), ClusterScore, CurrentDatabase, ReviewGeneratedAt, etc.
      - FailedChecksThatRequireAttention        (array of checks)
      - PassedChecksThatDoNotRequireAttention   (array of checks)
    A check's pass/fail state comes from which array it is in.
    Severities (Impact/WorstCaseImpact, RecommendationEffort, RecommendationRisk)
    are numeric: 1 = Low, 2 = Medium, 3 = High.

    Output: a single standalone, styled HTML report in a 'reports' folder.

.PARAMETER CustomerName
    Customer name shown in the report header.

.PARAMETER InputFolder
    Folder containing the *.json files. Defaults to the script's own folder.

.PARAMETER OutputRoot
    Root directory in which the 'reports' folder is created. Defaults to the
    parent of the input folder.

.EXAMPLE
    .\Generate-PostgreSQLReviewReport.ps1 -CustomerName "Finonex"
#>

[CmdletBinding()]
param(
    [string]$CustomerName = "Customer",

    # Folder containing the *.json review files. If omitted, the folder the
    # script itself lives in is used.
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { return $true }
        if (Test-Path -LiteralPath $_ -PathType Container) { return $true }
        throw "InputFolder '$_' does not exist or is not a folder."
    })]
    [string]$InputFolder,

    # Folder to write the HTML report into. If given, the report is written
    # directly here. If omitted, a 'reports' folder next to the input is used.
    [string]$OutputRoot,

    # Optional folder of per-test .sql scripts. Each script's leading /* */
    # description header supplies Scope, Category, What This Means, and
    # Recommendation, matched to a finding by the title text in the filename.
    # When a matching script is found, its header values override the JSON.
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { return $true }
        if (Test-Path -LiteralPath $_ -PathType Container) { return $true }
        throw "TestScriptsFolder '$_' does not exist or is not a folder."
    })]
    [string]$TestScriptsFolder
)

# StrictMode 1.0 still flags uninitialized variables but does NOT throw when a
# property (e.g. .Count) is read on a scalar/object that lacks it. The review
# JSON mixes scalars, single objects, and arrays across many optional fields,
# so the stricter 'Latest' mode caused PropertyNotFoundStrict errors.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------
function Get-ScriptFolder {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Get-Location).Path
}

$ScriptFolder = Get-ScriptFolder
if (-not $InputFolder -or [string]::IsNullOrWhiteSpace($InputFolder)) {
    $InputFolder = $ScriptFolder
}
if (-not $OutputRoot -or [string]::IsNullOrWhiteSpace($OutputRoot)) {
    # No output location given: default to a 'reports' folder next to the input.
    $parent = Split-Path -Parent $InputFolder
    if (-not $parent) { $parent = $InputFolder }
    $ReportsFolder = Join-Path $parent 'reports'
} else {
    # An explicit output location was given: write the report directly there,
    # without creating a nested 'reports' subfolder.
    $ReportsFolder = $OutputRoot
}

# ---------------------------------------------------------------------------
# Helper: safe property access with alternative names
# ---------------------------------------------------------------------------
function Get-FirstProperty {
    param(
        $Object,
        [Parameter(Mandatory)] [string[]] $Names,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    # Only objects with named properties are inspectable. Scalars (int, string,
    # bool) and arrays have no named check-properties to look up.
    if ($Object -is [ValueType] -or $Object -is [string] -or $Object -is [System.Array]) { return $Default }

    $propNames = @()
    try { $propNames = @($Object.PSObject.Properties.Name) } catch { return $Default }

    foreach ($name in $Names) {
        if ($propNames -contains $name) {
            $val = $Object.$name
            if ($null -ne $val -and -not ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                return $val
            }
        }
    }
    return $Default
}

# ---------------------------------------------------------------------------
# Helper: HTML-safe text
# ---------------------------------------------------------------------------
function ConvertTo-HtmlSafe {
    param($Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $s = $s -replace '&', '&amp;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    $s = $s -replace '"', '&quot;'
    $s = $s -replace "'", '&#39;'
    return $s
}

# ---------------------------------------------------------------------------
# Helper: map numeric or text severity to Low/Medium/High
# ---------------------------------------------------------------------------
function Get-SeverityLabel {
    param($Value, [string]$Default = 'Low')
    if ($null -eq $Value) { return $Default }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or ($Value -is [string] -and $Value -match '^\s*\d+\s*$')) {
        $n = [int]$Value
        if ($n -ge 3) { return 'High' }
        if ($n -eq 2) { return 'Medium' }
        if ($n -eq 1) { return 'Low' }
        return $Default
    }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -match 'high|crit') { return 'High' }
    if ($s -match 'med')       { return 'Medium' }
    if ($s -match 'low|info|minor') { return 'Low' }
    return $Default
}

function Get-SeverityWeight {
    param([string]$Severity)
    switch ($Severity) {
        'High'   { return 3 }
        'Medium' { return 2 }
        'Low'    { return 1 }
        default  { return 1 }
    }
}

function Get-SeverityClass {
    param([string]$Severity)
    switch ($Severity) {
        'High'   { return 'sev-high' }
        'Medium' { return 'sev-medium' }
        'Low'    { return 'sev-low' }
        default  { return 'sev-low' }
    }
}

# ---------------------------------------------------------------------------
# Helper: normalize scope. From now on the review emits only two scopes:
# 'Cluster-level' and 'Database-level'. Returns 'cluster' or 'database'.
# Used for display, grouping, "Applies to", the Database Summary, AND scoring
# (cluster score = cluster checks only; each database score = that database's
# database checks only).
# ---------------------------------------------------------------------------
function Get-ScopeLabel {
    param($Value)
    if ($null -eq $Value) { return 'database' }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -match 'cluster') { return 'cluster' }
    return 'database'
}

# ---------------------------------------------------------------------------
# Test-script metadata
# ---------------------------------------------------------------------------
# Normalize a title (or a filename) to a comparable key: drop extension and any
# leading numbering, turn separators into spaces, lowercase, keep only
# alphanumerics and single spaces. Used to match a .sql file to a JSON finding.
function Get-TitleKey {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $s = $Text
    $s = $s -replace '(?i)\.sql$', ''      # drop .sql extension
    $s = $s -replace '^[\s_\-]*\d+[\s_\-]*', ''  # drop leading number + separators
    $s = $s -replace '[_\-]', ' '          # underscores / dashes -> space
    $s = $s.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9]+', ' '     # non-alphanumerics -> space
    $s = $s.Trim()
    $s = $s -replace '\s+', ' '            # collapse whitespace
    return $s
}

# Parse a single label out of a /* ... */ header block. Captures text after
# "Label:" up to the next known label or end of block. Tolerates the plural
# "Recommendations" and inconsistent spacing around the colon. A word boundary
# after the label prevents "Recommendation" from matching inside
# "Recommendations" and leaking a stray "s".
function Get-HeaderField {
    param([string]$Header, [string[]]$Labels)
    $stop = 'What This Means|Recommendations|Recommendation|Scope|Category|More info'
    foreach ($label in $Labels) {
        $pattern = '(?ims)^\s*' + [regex]::Escape($label) + '\b\s*:?\s*(.*?)(?=^\s*(?:' + $stop + ')\b\s*:|\Z)'
        $m = [regex]::Match($Header, $pattern)
        if ($m.Success) {
            $v = $m.Groups[1].Value.Trim()
            $v = $v -replace '\s+', ' '
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        }
    }
    return $null
}

# Read every .sql in the folder and build a hashtable keyed by normalized title
# -> @{ Scope; Category; WhatThisMeans; Recommendation }.
function Get-TestScriptMetadata {
    param([string]$Folder)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Folder)) { return $map }
    $files = Get-ChildItem -Path $Folder -Filter '*.sql' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        } catch {
            Write-Warning "Could not read test script '$($file.Name)': $($_.Exception.Message)"
            continue
        }
        # First /* ... */ block is the description header.
        $hm = [regex]::Match($text, '(?s)/\*(.*?)\*/')
        if (-not $hm.Success) { continue }
        $header = $hm.Groups[1].Value

        $meta = @{
            Scope          = Get-HeaderField -Header $header -Labels @('Scope')
            Category       = Get-HeaderField -Header $header -Labels @('Category')
            WhatThisMeans  = Get-HeaderField -Header $header -Labels @('What This Means')
            Recommendation = Get-HeaderField -Header $header -Labels @('Recommendations','Recommendation')
        }

        $key = Get-TitleKey $file.Name
        if ($key) { $map[$key] = $meta }
    }
    return $map
}

# ---------------------------------------------------------------------------
# Loader: read a file, strip the SQL concat artifact, parse JSON
# ---------------------------------------------------------------------------
function Read-ReviewJson {
    param([string]$Path)

    # --- Decode bytes with encoding detection (UTF-8 / UTF-16, BOM or not) ---
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $raw = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $raw = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $raw = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    # The review JSON is exported from SQL and can arrive in one of several
    # shapes. Build candidate cleanups and return the first that parses:
    #   1. Clean JSON (no artifact)
    #   2. Line-concatenated: each line space-padded and terminated by '+'
    #   3. CSV-quoted: whole JSON wrapped in "..." with internal quotes doubled
    $candidates = @()

    # Candidate 1: as-is
    $candidates += $raw

    # Candidate 2: strip trailing '+' concatenation markers per line
    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in ($raw -split "`r?`n")) {
        $trimmed = $line.TrimEnd()
        if ($trimmed.EndsWith('+')) {
            $trimmed = $trimmed.Substring(0, $trimmed.Length - 1).TrimEnd()
        }
        [void]$sb.AppendLine($trimmed)
    }
    $candidates += $sb.ToString()

    # Candidate 3: unwrap surrounding double quotes and un-double internal ones
    $trimAll = $raw.Trim()
    if ($trimAll.Length -ge 2 -and $trimAll.StartsWith('"') -and $trimAll.EndsWith('"')) {
        $inner = $trimAll.Substring(1, $trimAll.Length - 2)
        $inner = $inner -replace '""', '"'
        $candidates += $inner

        # Candidate 4: unwrapped/undoubled AND '+'-stripped (both artifacts)
        $sb2 = [System.Text.StringBuilder]::new()
        foreach ($line in ($inner -split "`r?`n")) {
            $t = $line.TrimEnd()
            if ($t.EndsWith('+')) { $t = $t.Substring(0, $t.Length - 1).TrimEnd() }
            [void]$sb2.AppendLine($t)
        }
        $candidates += $sb2.ToString()
    }

    $lastError = 'no candidates'
    foreach ($cand in $candidates) {
        if ($null -eq $cand) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$cand)) { continue }
        $parsed = $null
        try {
            $parsed = $cand | ConvertFrom-Json
        }
        catch {
            $lastError = $_.Exception.Message
            continue
        }
        if ($null -eq $parsed) { $lastError = 'parsed to null'; continue }
        # If the content was just a quoted string, ConvertFrom-Json yields a
        # [string]; that means this candidate wasn't the real object - keep going.
        if ($parsed -is [string]) { $lastError = 'parsed to a bare string'; continue }
        return $parsed
    }
    throw "Could not parse JSON after trying clean / plus-stripped / unquoted variants. Last error: $lastError"
}

function Get-ReviewFiles {
    param([string]$Folder)
    $result = @()
    $files = Get-ChildItem -Path $Folder -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $dbName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        try {
            $parsed = Read-ReviewJson -Path $file.FullName
        }
        catch {
            Write-Warning "PARSE FAILED for '$($file.Name)': $($_.Exception.Message)"
            continue
        }
        if ($null -eq $parsed) { continue }
        $result += [PSCustomObject]@{ Database = $dbName; Root = $parsed }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Normalize a single raw check object
# ---------------------------------------------------------------------------
function ConvertTo-NormalizedCheck {
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] [string]$Database,
        [Parameter(Mandatory)] [bool]$Failed,
        $ScriptMeta = $null
    )

    $title    = Get-FirstProperty -Object $Raw -Names @('Title','CheckTitle','Name','CheckName') -Default 'Unnamed Check'
    $checkId  = Get-FirstProperty -Object $Raw -Names @('CheckId','Id','CheckID') -Default $title
    $category = Get-FirstProperty -Object $Raw -Names @('Category','Area','Group') -Default 'General'
    $scopeRaw = Get-FirstProperty -Object $Raw -Names @('Scope','Level') -Default 'Database-level'

    $impact = Get-SeverityLabel (Get-FirstProperty -Object $Raw -Names @('Impact','WorstCaseImpact','Severity') -Default $null)
    $effort = Get-SeverityLabel (Get-FirstProperty -Object $Raw -Names @('RecommendationEffort','Effort','EffortLevel') -Default $null)
    $risk   = Get-SeverityLabel (Get-FirstProperty -Object $Raw -Names @('RecommendationRisk','Risk','RiskLevel') -Default $null)

    $value  = Get-FirstProperty -Object $Raw -Names @('Value','Result','Finding') -Default $null
    $means  = Get-FirstProperty -Object $Raw -Names @('WhatThisMeans','Meaning','Explanation','Description') -Default $null
    $rec    = Get-FirstProperty -Object $Raw -Names @('Recommendation','Remediation','Advice','Action') -Default $null
    $addl   = Get-FirstProperty -Object $Raw -Names @('AdditionalInfo','Details','ResultSet','Rows','Data') -Default $null

    if ($null -eq $value -and $null -ne $addl) {
        $fr = Get-FirstProperty -Object $addl -Names @('FindingReason','Finding','Reason') -Default $null
        if ($fr) { $value = $fr }
    }
    if ([string]::IsNullOrWhiteSpace([string]$means) -and $null -ne $addl) {
        $fr = Get-FirstProperty -Object $addl -Names @('FindingReason','Finding','Reason') -Default $null
        if ($fr) { $means = $fr }
    }

    # Override Scope, Category, What This Means, and Recommendation from the
    # matching test script's header when one is found (matched by title).
    $sourcedFromScript = $false
    if ($null -ne $ScriptMeta -and $ScriptMeta -is [hashtable] -and $ScriptMeta.Count -gt 0) {
        $key = Get-TitleKey ([string]$title)
        if ($key -and $ScriptMeta.ContainsKey($key)) {
            $sm = $ScriptMeta[$key]
            if (-not [string]::IsNullOrWhiteSpace([string]$sm.Scope))          { $scopeRaw = [string]$sm.Scope }
            if (-not [string]::IsNullOrWhiteSpace([string]$sm.Category))       { $category = [string]$sm.Category }
            if (-not [string]::IsNullOrWhiteSpace([string]$sm.WhatThisMeans))  { $means    = [string]$sm.WhatThisMeans }
            if (-not [string]::IsNullOrWhiteSpace([string]$sm.Recommendation)) { $rec      = [string]$sm.Recommendation }
            $sourcedFromScript = $true
        }
    }

    $scope = Get-ScopeLabel $scopeRaw

    [PSCustomObject]@{
        Database          = $Database
        CheckId           = [string]$checkId
        Title             = [string]$title
        Category          = [string]$category
        ScopeRaw          = [string]$scopeRaw
        Scope             = $scope
        Failed            = $Failed
        Impact            = $impact
        Effort            = $effort
        Risk              = $risk
        Value             = $value
        WhatThisMeans     = [string]$means
        Recommendation    = [string]$rec
        AdditionalInfo    = $addl
        SourcedFromScript = $sourcedFromScript
    }
}

# ---------------------------------------------------------------------------
# Cluster metadata
# ---------------------------------------------------------------------------
function Get-ClusterMetadata {
    param([array]$Files)
    $meta = [ordered]@{
        Version = 'Not provided'; StartTime = 'Not provided'; Uptime = 'Not provided'
        GeneratedAt = 'Not provided'; Assessment = 'PostgreSQL Review'; ClusterName = 'Not provided'
    }
    foreach ($f in $Files) {
        $root = $f.Root

        # Server identity lives under SystemIntroduction.ServerIdentity, with
        # lowercase field names (postgresqlversion, postgresqlstarttime, etc.).
        $sysIntro = Get-FirstProperty -Object $root -Names @('SystemIntroduction') -Default $null
        $identity = Get-FirstProperty -Object $sysIntro -Names @('ServerIdentity') -Default $null

        if ($meta.Version -eq 'Not provided') {
            $v = Get-FirstProperty -Object $identity -Names @('postgresqlversion','PostgreSQLVersion') -Default $null
            if (-not $v) { $v = Get-FirstProperty -Object $root -Names @('PostgreSQLVersion','PostgresVersion','PgVersion','ServerVersion','Version') -Default $null }
            if ($v) { $meta.Version = [string]$v }
        }
        if ($meta.StartTime -eq 'Not provided') {
            $s = Get-FirstProperty -Object $identity -Names @('postgresqlstarttime','PostgreSQLStartTime') -Default $null
            if (-not $s) { $s = Get-FirstProperty -Object $root -Names @('PostgreSQLStartTime','StartTime','PgStartTime') -Default $null }
            if ($s) { $meta.StartTime = [string]$s }
        }
        if ($meta.Uptime -eq 'Not provided') {
            $u = Get-FirstProperty -Object $identity -Names @('postgresqluptime','PostgreSQLUptime') -Default $null
            if (-not $u) { $u = Get-FirstProperty -Object $root -Names @('PostgreSQLUptime','Uptime','PgUptime') -Default $null }
            if ($u) { $meta.Uptime = [string]$u }
        }
        if ($meta.GeneratedAt -eq 'Not provided') {
            $g = Get-FirstProperty -Object $root -Names @('ReviewGeneratedAt','GeneratedAt') -Default $null
            if ($g) { $meta.GeneratedAt = [string]$g }
        }
        $a = Get-FirstProperty -Object $root -Names @('AssessmentType') -Default $null
        if ($a) { $meta.Assessment = [string]$a }
        if ($meta.ClusterName -eq 'Not provided') {
            $cn = Get-FirstProperty -Object $identity -Names @('postgresqlclustername') -Default $null
            if (-not $cn) { $cn = Get-FirstProperty -Object $root -Names @('PostgreSQLClusterName','ClusterName') -Default $null }
            if ($cn) { $meta.ClusterName = [string]$cn }
        }
    }
    return $meta
}

# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
function Get-Score {
    param([array]$Checks)
    if (-not $Checks -or $Checks.Count -eq 0) { return 100 }
    $totalWeight = 0.0; $penaltyWeight = 0.0
    foreach ($c in $Checks) {
        $w = Get-SeverityWeight -Severity $c.Impact
        $totalWeight += $w
        if ($c.Failed) { $penaltyWeight += $w }
    }
    if ($totalWeight -le 0) { return 100 }
    $score = [Math]::Round(100.0 * (1.0 - ($penaltyWeight / $totalWeight)))
    if ($score -lt 1) { $score = 1 }
    if ($score -gt 100) { $score = 100 }
    return [int]$score
}

function Get-ScoreBand {
    param([int]$Score)
    if ($Score -ge 90) { return 'Excellent' }
    if ($Score -ge 75) { return 'Good' }
    if ($Score -ge 60) { return 'Acceptable' }
    if ($Score -ge 40) { return 'NeedsAttention' }
    return 'Critical'
}
function Get-ScoreBandText {
    param([int]$Score)
    if ((Get-ScoreBand $Score) -eq 'NeedsAttention') { return 'Needs Attention' }
    return (Get-ScoreBand $Score)
}

# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------
function Format-CellValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return (ConvertTo-HtmlSafe ($Value.ToString().ToLower())) }
    if ($Value -is [System.Array]) { return (ConvertTo-HtmlSafe (($Value | ForEach-Object { [string]$_ }) -join ', ')) }
    if ($Value -is [PSCustomObject]) {
        try { return (ConvertTo-HtmlSafe ($Value | ConvertTo-Json -Compress -Depth 6)) }
        catch { return (ConvertTo-HtmlSafe ([string]$Value)) }
    }
    return (ConvertTo-HtmlSafe ([string]$Value))
}

function Get-RowsTableHtml {
    param([array]$Rows, [string]$LeadColumnName, [string]$LeadColumnValue)
    $columnOrder = @(); $normRows = @()
    foreach ($rec in $Rows) {
        if ($null -eq $rec) { continue }
        $row = [ordered]@{}
        if ($LeadColumnName) { $row[$LeadColumnName] = $LeadColumnValue }
        if ($rec -is [PSCustomObject]) { foreach ($p in $rec.PSObject.Properties) { $row[$p.Name] = $p.Value } }
        else { $row['Value'] = $rec }
        foreach ($k in $row.Keys) { if ($columnOrder -notcontains $k) { $columnOrder += $k } }
        $normRows += ,$row
    }
    if ($normRows.Count -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table class="result-table"><thead><tr>')
    foreach ($col in $columnOrder) { [void]$sb.Append('<th>' + (ConvertTo-HtmlSafe $col) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $normRows) {
        [void]$sb.Append('<tr>')
        foreach ($col in $columnOrder) {
            $cell = if ($row.Contains($col)) { Format-CellValue $row[$col] } else { '' }
            [void]$sb.Append('<td>' + $cell + '</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Get-AdditionalInfoHtml {
    param([array]$GroupChecks, [string]$Scope)
    $sb = [System.Text.StringBuilder]::new()
    $rendered = $false
    foreach ($c in $GroupChecks) {
        $addl = $c.AdditionalInfo
        if ($null -eq $addl) { continue }
        $dbLabel = if ($Scope -eq 'database') { $c.Database } else { $null }

        $scalarRow = [ordered]@{}
        $arrayFields = @()
        if ($addl -is [PSCustomObject]) {
            foreach ($p in $addl.PSObject.Properties) {
                $v = $p.Value
                if ($v -is [System.Array]) { $arrayFields += [PSCustomObject]@{ Name = $p.Name; Rows = @($v) } }
                elseif ($v -is [PSCustomObject]) { $arrayFields += [PSCustomObject]@{ Name = $p.Name; Rows = @($v) } }
                else { $scalarRow[$p.Name] = $v }
            }
        } elseif ($addl -is [System.Array]) {
            $arrayFields += [PSCustomObject]@{ Name = 'Details'; Rows = @($addl) }
        } else {
            $scalarRow['Value'] = $addl
        }

        $scalarKeys = @($scalarRow.Keys)
        if ($scalarKeys.Count -gt 0) {
            $rendered = $true
            [void]$sb.Append('<table class="result-table"><thead><tr>')
            if ($dbLabel) { [void]$sb.Append('<th>Database</th>') }
            [void]$sb.Append('<th>Field</th><th>Value</th></tr></thead><tbody>')
            foreach ($k in $scalarKeys) {
                [void]$sb.Append('<tr>')
                if ($dbLabel) { [void]$sb.Append('<td>' + (ConvertTo-HtmlSafe $dbLabel) + '</td>') }
                [void]$sb.Append('<td>' + (ConvertTo-HtmlSafe $k) + '</td>')
                [void]$sb.Append('<td>' + (Format-CellValue $scalarRow[$k]) + '</td>')
                [void]$sb.Append('</tr>')
            }
            [void]$sb.Append('</tbody></table>')
        }

        foreach ($af in $arrayFields) {
            $lead = if ($dbLabel) { 'Database' } else { $null }
            $tbl = Get-RowsTableHtml -Rows $af.Rows -LeadColumnName $lead -LeadColumnValue $dbLabel
            if ($tbl) {
                $rendered = $true
                [void]$sb.Append('<div class="result-subtitle">' + (ConvertTo-HtmlSafe $af.Name) + '</div>')
                [void]$sb.Append($tbl)
            }
        }
    }
    if (-not $rendered) { return '<p class="muted">No additional detail available.</p>' }
    return $sb.ToString()
}

function Get-TestBlockHtml {
    param([array]$GroupChecks, [int]$TotalDatabases)
    $first = $GroupChecks[0]
    $scope = $first.Scope
    $title = ConvertTo-HtmlSafe $first.Title
    $category = ConvertTo-HtmlSafe $first.Category
    $scopeText = ConvertTo-HtmlSafe $first.ScopeRaw

    $failedOnes = @($GroupChecks | Where-Object { $_.Failed })
    $headline = if ($failedOnes.Count -gt 0) {
        $failedOnes | Sort-Object { Get-SeverityWeight $_.Impact } -Descending | Select-Object -First 1
    } else {
        $GroupChecks | Sort-Object { Get-SeverityWeight $_.Impact } -Descending | Select-Object -First 1
    }

    $impact = $headline.Impact; $effort = $headline.Effort; $risk = $headline.Risk
    $value = Format-CellValue $headline.Value
    $means = ConvertTo-HtmlSafe $headline.WhatThisMeans
    $rec = ConvertTo-HtmlSafe $headline.Recommendation
    $anyFailed = $failedOnes.Count -gt 0
    $stateClass = if ($anyFailed) { 'test-failed' } else { 'test-passed' }

    $appliesTo = ''
    if ($scope -eq 'database') {
        $affected = if ($anyFailed) { $failedOnes.Count } else { @($GroupChecks).Count }
        $appliesTo = "<span class=""meta-item""><strong>Applies to:</strong> $affected of $TotalDatabases databases</span>"
    }

    $impactClass = Get-SeverityClass $impact
    $effortClass = Get-SeverityClass $effort
    $riskClass   = Get-SeverityClass $risk

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<div class=""test-block $stateClass"">")
    [void]$sb.Append("<div class=""test-title-row""><span class=""test-title"">$title</span></div>")

    [void]$sb.Append('<div class="meta-row">')
    [void]$sb.Append("<span class=""meta-item""><strong>Scope:</strong> $scopeText</span>")
    [void]$sb.Append("<span class=""meta-item""><strong>Category:</strong> $category</span>")
    [void]$sb.Append($appliesTo)
    [void]$sb.Append('</div>')

    # Value on its own row
    if ($value) {
        [void]$sb.Append('<div class="meta-row">')
        [void]$sb.Append("<span class=""meta-item""><strong>Value:</strong> $value</span>")
        [void]$sb.Append('</div>')
    }

    # Impact / Effort / Risk on a separate row
    [void]$sb.Append('<div class="meta-row">')
    [void]$sb.Append("<span class=""pill $impactClass"">Impact: $impact</span>")
    [void]$sb.Append("<span class=""pill $effortClass"">Effort: $effort</span>")
    [void]$sb.Append("<span class=""pill $riskClass"">Risk: $risk</span>")
    [void]$sb.Append('</div>')

    if ($means) { [void]$sb.Append("<div class=""text-block""><span class=""label"">What This Means</span><p>$means</p></div>") }
    if ($rec)   { [void]$sb.Append("<div class=""text-block""><span class=""label"">Recommendation</span><p>$rec</p></div>") }

    [void]$sb.Append('<details class="addl"><summary>Additional Info</summary><div class="addl-body">')
    # Show detail only for the failing instances (affected databases).
    $detailChecks = if ($failedOnes.Count -gt 0) { $failedOnes } else { $GroupChecks }
    [void]$sb.Append((Get-AdditionalInfoHtml -GroupChecks $detailChecks -Scope $scope))
    [void]$sb.Append('</div></details>')
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Section renderers
# ---------------------------------------------------------------------------
function Get-HeaderSectionHtml {
    param([string]$Customer,$Meta,[int]$DbCount,[int]$ClusterScore,[int]$TotalChecks,[int]$PassedChecks,[int]$FailedChecks)
    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $band = Get-ScoreBandText $ClusterScore
    $bandClass = Get-ScoreBand $ClusterScore
    $verPart = if ($Meta.Version -ne 'Not provided') { " running PostgreSQL $($Meta.Version)" } else { '' }
    $exec = "This $($Meta.Assessment) evaluated $DbCount database(s) on one cluster$verPart. " +
        "A total of $TotalChecks checks were assessed, of which $PassedChecks passed and $FailedChecks require attention. " +
        "The cluster achieved an overall score of $ClusterScore/100, placing it in the '$band' band. " +
        "Findings below are prioritized by impact, effort, and risk to support remediation planning."

    @"
<section class="card header-card">
  <div class="header-top">
    <div>
      <h1>PostgreSQL Review Report</h1>
      <p class="subtitle">Prepared for $(ConvertTo-HtmlSafe $Customer)</p>
    </div>
    <div class="score-badge score-$bandClass">
      <div class="score-number">$ClusterScore</div>
      <div class="score-label">/ 100 &middot; $band</div>
    </div>
  </div>
  <table class="meta-table">
    <tr><th>Customer</th><td>$(ConvertTo-HtmlSafe $Customer)</td>
        <th>PostgreSQL Version</th><td>$(ConvertTo-HtmlSafe $Meta.Version)</td></tr>
    <tr><th>Databases Included</th><td>$DbCount</td>
        <th>Report Generated</th><td>$generated</td></tr>
    <tr><th>PostgreSQL Start Time</th><td>$(ConvertTo-HtmlSafe $Meta.StartTime)</td>
        <th>PostgreSQL Uptime</th><td>$(ConvertTo-HtmlSafe $Meta.Uptime)</td></tr>
    <tr><th>Total Checks</th><td>$TotalChecks</td>
        <th>Passed / Failed</th><td>$PassedChecks / $FailedChecks</td></tr>
  </table>
  <div class="exec-summary">
    <h2>Executive Summary</h2>
    <p>$(ConvertTo-HtmlSafe $exec)</p>
  </div>
</section>
"@
}

function Get-ClusterScoreSectionHtml {
    param([int]$Score,[int]$Passed,[int]$Failed,[int]$Total)
    $band = Get-ScoreBandText $Score
    $bandClass = Get-ScoreBand $Score
    $pct = if ($Total -gt 0) { [Math]::Round(100.0 * $Passed / $Total) } else { 100 }
    @"
<section class="card">
  <h2>Cluster Score</h2>
  <div class="cluster-score-wrap">
    <div class="big-score score-$bandClass">$Score<span>/100</span></div>
    <div class="score-detail">
      <p><strong>Band:</strong> $band</p>
      <p><strong>Cluster-level checks passed:</strong> $Passed of $Total ($pct%)</p>
      <p><strong>Cluster-level checks requiring attention:</strong> $Failed</p>
      <p class="muted small">Score is weighted by impact (High findings reduce it more than Low), so it may differ from the raw pass percentage.</p>
      <div class="progress"><div class="progress-fill score-$bandClass" style="width:$Score%"></div></div>
    </div>
  </div>
</section>
"@
}

function Get-TestResultsSectionHtml {
    param([array]$Groups,[int]$TotalDatabases)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<section class="card"><h2>Test Results</h2>')
    [void]$sb.Append('<p class="muted">Findings that require attention. Passed checks are listed separately below.</p>')

    # Only show groups that have at least one failed check.
    $failedGroups = @($Groups | Where-Object { @($_.Checks | Where-Object { $_.Failed }).Count -gt 0 })
    if ($failedGroups.Count -eq 0) {
        [void]$sb.Append('<p class="badge badge-pass">No checks require attention.</p></section>')
        return $sb.ToString()
    }
    foreach ($g in $failedGroups) { [void]$sb.Append((Get-TestBlockHtml -GroupChecks $g.Checks -TotalDatabases $TotalDatabases)) }
    [void]$sb.Append('</section>')
    return $sb.ToString()
}

function Get-DatabaseSummarySectionHtml {
    param([array]$Checks,[hashtable]$DbScores)
    $dbGroups = $Checks | Where-Object { $_.Scope -eq 'database' -and $_.Failed } | Group-Object Database
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<section class="card"><h2>Database Summary</h2>')
    [void]$sb.Append('<p class="muted">Failed database-level checks, grouped by database.</p>')
    if (@($dbGroups).Count -eq 0) {
        [void]$sb.Append('<p class="badge badge-pass">No failed database-level checks.</p></section>')
        return $sb.ToString()
    }
    foreach ($dg in ($dbGroups | Sort-Object Name)) {
        $db = $dg.Name
        $score = if ($DbScores.ContainsKey($db)) { $DbScores[$db] } else { 100 }
        $bandClass = Get-ScoreBand $score
        [void]$sb.Append("<div class=""db-summary""><h3>$(ConvertTo-HtmlSafe $db) <span class=""db-score score-$bandClass"">Score: $score/100</span></h3>")
        [void]$sb.Append('<table class="finding-table"><thead><tr><th>Finding</th><th>Impact</th><th>Effort</th><th>Risk</th></tr></thead><tbody>')
        foreach ($c in ($dg.Group | Sort-Object { Get-SeverityWeight $_.Impact } -Descending)) {
            $ic = Get-SeverityClass $c.Impact; $ec = Get-SeverityClass $c.Effort; $rc = Get-SeverityClass $c.Risk
            [void]$sb.Append('<tr>')
            [void]$sb.Append('<td>' + (ConvertTo-HtmlSafe $c.Title) + '</td>')
            [void]$sb.Append("<td><span class=""pill $ic"">$($c.Impact)</span></td>")
            [void]$sb.Append("<td><span class=""pill $ec"">$($c.Effort)</span></td>")
            [void]$sb.Append("<td><span class=""pill $rc"">$($c.Risk)</span></td>")
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</tbody></table></div>')
    }
    [void]$sb.Append('</section>')
    return $sb.ToString()
}

function Get-PassedChecksSectionHtml {
    param([array]$Groups)
    $passedGroups = @($Groups | Where-Object { -not (@($_.Checks | Where-Object { $_.Failed }).Count -gt 0) })
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<section class="card"><h2>Passed Checks</h2>')
    if ($passedGroups.Count -eq 0) {
        [void]$sb.Append('<p class="muted">No checks passed across all databases.</p></section>')
        return $sb.ToString()
    }
    [void]$sb.Append('<p class="muted">Checks successful in all databases.</p><ul class="passed-list">')
    foreach ($g in ($passedGroups | Sort-Object { $_.Checks[0].Title })) {
        $c = $g.Checks[0]
        [void]$sb.Append('<li><span class="badge badge-pass">Pass</span> ' + (ConvertTo-HtmlSafe $c.Title) +
            ' <span class="muted small">(' + (ConvertTo-HtmlSafe $c.Category) + ' &middot; ' + (ConvertTo-HtmlSafe $c.ScopeRaw) + ')</span></li>')
    }
    [void]$sb.Append('</ul></section>')
    return $sb.ToString()
}

function Get-AboutSectionHtml {
    $t1 = "This assessment is a PostgreSQL Review covering configuration, maintenance, observability, statistics, and replication signals collected through SQL against nine application databases on one cluster. Object-level checks (tables, indexes, statistics, bloat) apply only to the specific database in which they were collected; cluster-level checks apply to the whole cluster. The Review does not replace a full architectural review, capacity plan, or application code review."
    $t2 = "The findings are based on the collected data at the time of execution. Runtime conditions such as blocking, active sessions, temporary file usage, replication lag, and connection pressure change over time and should be correlated with monitoring data where available. Because results are collected per database, the Review should continue to be executed separately against each relevant application database, or results merged from multiple executions, as was done here."
    @"
<section class="card about-card">
  <h2>About This Assessment</h2>
  <p>$(ConvertTo-HtmlSafe $t1)</p>
  <p>$(ConvertTo-HtmlSafe $t2)</p>
</section>
"@
}

function Get-ReportCss {
@"
:root{
  --high:#c0392b; --medium:#e67e22; --low:#7f8c8d; --pass:#27ae60;
  --ink:#1f2d3d; --muted:#6b7a8d; --line:#e2e8f0; --bg:#f4f6f9; --card:#ffffff; --accent:#2c5282;
}
*{box-sizing:border-box}
body{font-family:'Segoe UI',Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--ink);margin:0;padding:32px;line-height:1.55;font-size:14px}
.container{max-width:1080px;margin:0 auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:26px 30px;margin-bottom:24px;box-shadow:0 1px 3px rgba(0,0,0,.05)}
h1{margin:0;font-size:26px;color:var(--accent)}
h2{margin:0 0 16px;font-size:20px;color:var(--accent);border-bottom:2px solid var(--line);padding-bottom:8px}
h3{margin:22px 0 10px;font-size:16px}
.subtitle{margin:4px 0 0;color:var(--muted);font-size:15px}
.header-top{display:flex;justify-content:space-between;align-items:center;gap:20px}
.score-badge{text-align:center;border-radius:10px;padding:14px 22px;color:#fff;min-width:120px}
.score-number{font-size:34px;font-weight:700;line-height:1}
.score-label{font-size:12px;opacity:.95}
.meta-table{width:100%;border-collapse:collapse;margin-top:20px}
.meta-table th,.meta-table td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);font-size:13px}
.meta-table th{color:var(--muted);font-weight:600;width:18%}
.exec-summary{margin-top:20px;background:#f8fafc;border-left:4px solid var(--accent);padding:14px 18px;border-radius:0 6px 6px 0}
.exec-summary h2{border:none;padding:0;margin-bottom:8px;font-size:16px}
.cluster-score-wrap{display:flex;gap:30px;align-items:center;flex-wrap:wrap}
.big-score{font-size:64px;font-weight:800;color:#fff;border-radius:12px;padding:16px 26px;min-width:150px;text-align:center}
.big-score span{font-size:22px;font-weight:500;opacity:.9}
.score-detail{flex:1;min-width:240px}
.score-detail p{margin:4px 0}
.progress{height:12px;background:var(--line);border-radius:6px;overflow:hidden;margin-top:10px}
.progress-fill{height:100%}
.test-block{border:1px solid var(--line);border-left-width:5px;border-radius:8px;padding:16px 18px;margin-bottom:16px;background:#fff}
.test-failed{border-left-color:var(--high)}
.test-passed{border-left-color:var(--pass)}
.test-title-row{display:flex;justify-content:space-between;align-items:center;gap:12px}
.test-title{font-size:16px;font-weight:700}
.meta-row{display:flex;flex-wrap:wrap;gap:10px 18px;margin-top:10px;align-items:center}
.meta-item{font-size:13px}
.meta-item strong{color:var(--muted);font-weight:600}
.pill{display:inline-block;padding:2px 10px;border-radius:12px;font-size:12px;font-weight:600;color:#fff}
.sev-high{background:var(--high)}.sev-medium{background:var(--medium)}.sev-low{background:var(--low)}
.badge{display:inline-block;padding:3px 10px;border-radius:12px;font-size:12px;font-weight:600;color:#fff}
.badge-fail{background:var(--high)}.badge-pass{background:var(--pass)}
.text-block{margin-top:12px}
.text-block .label{display:block;font-size:12px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);font-weight:700;margin-bottom:3px}
.text-block p{margin:0}
.addl{margin-top:12px;border:1px solid var(--line);border-radius:6px;background:#fafbfc}
.addl summary{cursor:pointer;padding:10px 14px;font-weight:600;color:var(--accent);user-select:none}
.addl summary:hover{background:#f0f4f9}
.addl-body{padding:12px 14px;overflow-x:auto}
.result-subtitle{font-weight:600;color:var(--muted);margin:14px 0 6px;font-size:13px}
.result-table,.finding-table{width:100%;border-collapse:collapse;font-size:13px;margin-bottom:8px}
.result-table th,.result-table td,.finding-table th,.finding-table td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top}
.result-table th,.finding-table th{background:#eef2f7;font-weight:600}
.result-table tbody tr:nth-child(even){background:#fafbfc}
.db-summary{margin-bottom:22px}
.db-summary h3{display:flex;align-items:center;gap:12px}
.db-score{font-size:12px;padding:3px 10px;border-radius:12px;color:#fff;font-weight:600}
.passed-list{list-style:none;padding:0;margin:0}
.passed-list li{padding:6px 0;border-bottom:1px solid var(--line)}
.muted{color:var(--muted)}.small{font-size:12px}
.about-card p{margin:0 0 12px}
.score-Excellent{background:#1e7e34}.score-Good{background:#27ae60}.score-Acceptable{background:#e67e22}
.score-NeedsAttention{background:#d35400}.score-Critical{background:#c0392b}
footer{text-align:center;color:var(--muted);font-size:12px;margin-top:16px}
"@
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host "Reading JSON files from: $InputFolder"
$files = Get-ReviewFiles -Folder $InputFolder
if (-not $files -or $files.Count -eq 0) {
    Write-Error "No readable *.json files found in '$InputFolder'. Nothing to report."
    return
}

# Optional: load per-test .sql header metadata for overrides.
$scriptMeta = @{}
if (-not [string]::IsNullOrWhiteSpace($TestScriptsFolder)) {
    Write-Host "Reading test scripts from: $TestScriptsFolder"
    $scriptMeta = Get-TestScriptMetadata -Folder $TestScriptsFolder
    Write-Host "  Parsed $($scriptMeta.Count) test script header(s)."
}

$allChecks = @()
foreach ($f in $files) {
    $failedArr = @(Get-FirstProperty -Object $f.Root -Names @('FailedChecksThatRequireAttention','FailedChecks','Failed') -Default @())
    $passedArr = @(Get-FirstProperty -Object $f.Root -Names @('PassedChecksThatDoNotRequireAttention','PassedChecks','Passed') -Default @())
    foreach ($raw in $failedArr) { if ($null -ne $raw) { $allChecks += (ConvertTo-NormalizedCheck -Raw $raw -Database $f.Database -Failed $true  -ScriptMeta $scriptMeta) } }
    foreach ($raw in $passedArr) { if ($null -ne $raw) { $allChecks += (ConvertTo-NormalizedCheck -Raw $raw -Database $f.Database -Failed $false -ScriptMeta $scriptMeta) } }
}
$allChecks = @($allChecks)

if ($allChecks.Count -eq 0) {
    Write-Error "Files were read but contained no checks in the expected arrays."
    return
}

$databases    = @($files | Select-Object -ExpandProperty Database -Unique)
$dbCount      = $databases.Count
$totalChecks  = $allChecks.Count
$passedChecks = @($allChecks | Where-Object { -not $_.Failed }).Count
$failedChecks = @($allChecks | Where-Object { $_.Failed }).Count
$meta         = Get-ClusterMetadata -Files $files

# Cluster score: computed from cluster-level checks only, independent of
# per-database findings. Cluster checks repeat across files, so score the
# distinct set once, keyed by CheckId.
$clusterChecks = @($allChecks | Where-Object { $_.Scope -eq 'cluster' })
$clusterDistinct = @()
$seenClusterIds = @{}
foreach ($c in $clusterChecks) {
    if (-not $seenClusterIds.ContainsKey($c.CheckId)) {
        $seenClusterIds[$c.CheckId] = $true
        $clusterDistinct += $c
    }
}
if ($clusterDistinct.Count -gt 0) { $clusterScore = Get-Score -Checks $clusterDistinct }
else { $clusterScore = Get-Score -Checks $allChecks }

# Cluster-only counts for the Cluster Score panel (not the global totals).
$clusterTotal  = @($clusterDistinct).Count
$clusterPassed = @($clusterDistinct | Where-Object { -not $_.Failed }).Count
$clusterFailed = @($clusterDistinct | Where-Object { $_.Failed }).Count

# Per-database score: computed from that database's database-level checks only.
$dbScores = @{}
foreach ($f in $files) {
    $dbLevel = @($allChecks | Where-Object { $_.Database -eq $f.Database -and $_.Scope -eq 'database' })
    if ($dbLevel.Count -gt 0) { $dbScores[$f.Database] = Get-Score -Checks $dbLevel }
    else { $dbScores[$f.Database] = 100 }
}

$groups = @()
$grouped = $allChecks | Group-Object { if ($_.CheckId) { $_.CheckId } else { $_.Title } }
foreach ($g in $grouped) { $groups += [PSCustomObject]@{ Key = $g.Name; Checks = @($g.Group) } }
$groups = $groups | Sort-Object `
    @{ Expression = { if (@($_.Checks | Where-Object { $_.Failed }).Count -gt 0) { 0 } else { 1 } } }, `
    @{ Expression = { -1 * (Get-SeverityWeight ($_.Checks[0].Impact)) } }, `
    @{ Expression = { $_.Checks[0].Title } }

$headerHtml    = Get-HeaderSectionHtml -Customer $CustomerName -Meta $meta -DbCount $dbCount -ClusterScore $clusterScore -TotalChecks $totalChecks -PassedChecks $passedChecks -FailedChecks $failedChecks
$scoreHtml     = Get-ClusterScoreSectionHtml -Score $clusterScore -Passed $clusterPassed -Failed $clusterFailed -Total $clusterTotal
$testsHtml     = Get-TestResultsSectionHtml -Groups $groups -TotalDatabases $dbCount
$dbSummaryHtml = Get-DatabaseSummarySectionHtml -Checks $allChecks -DbScores $dbScores
$passedHtml    = Get-PassedChecksSectionHtml -Groups $groups
$aboutHtml     = Get-AboutSectionHtml
$generatedStamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PostgreSQL Review Report - $(ConvertTo-HtmlSafe $CustomerName)</title>
<style>
$(Get-ReportCss)
</style>
</head>
<body>
<div class="container">
$headerHtml
$scoreHtml
$testsHtml
$dbSummaryHtml
$passedHtml
$aboutHtml
<footer>Generated $generatedStamp &middot; PostgreSQL Review Report</footer>
</div>
</body>
</html>
"@

if (-not (Test-Path -LiteralPath $ReportsFolder)) { New-Item -ItemType Directory -Path $ReportsFolder -Force | Out-Null }
$safeCustomer = ($CustomerName -replace '[^\w\-]', '_')
$outFile = Join-Path $ReportsFolder ("PostgreSQL_Review_{0}_{1}.html" -f $safeCustomer, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$html | Out-File -LiteralPath $outFile -Encoding UTF8

Write-Host ""
Write-Host "Report generated successfully."
Write-Host "  Databases : $dbCount"
Write-Host "  Checks    : $totalChecks (Passed: $passedChecks, Failed: $failedChecks)"
Write-Host "  Cluster   : $clusterScore/100 ($(Get-ScoreBandText $clusterScore))"
Write-Host "  Output    : $outFile"
