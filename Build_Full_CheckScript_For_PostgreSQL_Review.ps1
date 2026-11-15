Param
(
 [string]$OutputScriptFilePath = "PostgreSQL_Review_Full_Check_Script.sql"
,[string]$TemplateHeaderFilePath = "Template/Template_Header.sql"
,[string]$TemplateFooterFilePath = "Template/Template_Footer.sql"
,[string]$CheckTemplateHeaderFilePath = "Template/Check_Header.sql"
,[string]$CheckTemplateFooterFilePath = "Template/Check_Footer.sql"
,[string]$CheckScriptsFolderPath = "SQLChecks\*"
,[string]$CheckScriptsFilter = "*.sql"
,[string]$InsightTemplateHeaderFilePath = "Template/Insight_Header.sql"
,[string]$InsightTemplateFooterFilePath = "Template/Insight_Footer.sql"
,[string]$InsightScriptsFolderPath = "SQLInsights\*"
,[string]$InsightScriptsFilter = "*.sql"
)

Set-ExecutionPolicy Bypass -Scope Process -Force

$batchSeparator = "`r`n`r`n"
$OutputScriptBuilder = [string](Get-Content -Path $TemplateHeaderFilePath -Raw)

$CheckHeaderTemplate = [string](Get-Content -Path $CheckTemplateHeaderFilePath -Raw)
$CheckFooterTemplate = [string](Get-Content -Path $CheckTemplateFooterFilePath -Raw)

[int]$CheckId = 0

Get-ChildItem -Path $CheckScriptsFolderPath -Include $CheckScriptsFilter | ForEach-Object {
    $CheckId += 1
    #$CheckTitle = $($_.BaseName)
    $CheckTitle = $_.BaseName -replace '^\d+\s*-\s*', ''
    Write-Output "Check $CheckId : $CheckTitle"

    $OutputScriptBuilder += $batchSeparator
    $OutputScriptBuilder += $CheckHeaderTemplate.Replace('{CheckId}', $CheckId).Replace('{CheckTitle}', $CheckTitle)
    $OutputScriptBuilder += [string](Get-Content -Path $_.FullName -Raw).Replace('{CheckId}', $CheckId).Replace('{CheckTitle}', $CheckTitle)
    $OutputScriptBuilder += $CheckFooterTemplate.Replace('{CheckId}', $CheckId).Replace('{CheckTitle}', $CheckTitle)
}

# Performance Insights: standalone ranked SELECTs. Each one is wrapped so that its
# result set is stored in pg_review_insights and returned in the review JSON's
# PerformanceInsights array. Scope, Topic Area and Requires Extension are read
# from the insight's header comment.
function Get-InsightHeaderValue([string]$Text, [string]$Label) {
    $m = [regex]::Match($Text, '(?im)^\s*' + [regex]::Escape($Label) + '\s*:\s*(?<v>[^\r\n]+)')
    if ($m.Success) { return $m.Groups['v'].Value.Trim() }
    return ''
}

if ((Test-Path -Path $InsightTemplateHeaderFilePath) -and (Test-Path -Path $InsightTemplateFooterFilePath)) {
    $InsightHeaderTemplate = [string](Get-Content -Path $InsightTemplateHeaderFilePath -Raw)
    $InsightFooterTemplate = [string](Get-Content -Path $InsightTemplateFooterFilePath -Raw)

    [int]$InsightId = 0

    Get-ChildItem -Path $InsightScriptsFolderPath -Include $InsightScriptsFilter -ErrorAction SilentlyContinue | ForEach-Object {
        $InsightId += 1
        $InsightTitle = $_.BaseName -replace '^\d+\s*-\s*', ''
        Write-Output "Insight $InsightId : $InsightTitle"

        $InsightBody = [string](Get-Content -Path $_.FullName -Raw)
        $Scope       = Get-InsightHeaderValue $InsightBody 'Scope'
        $TopicArea   = Get-InsightHeaderValue $InsightBody 'Topic Area'
        $Extensions  = @((Get-InsightHeaderValue $InsightBody 'Requires Extension') -split '[,\s]+' |
                         Where-Object { $_ -and $_ -notmatch '^(?i:none|n/a)$' })
        foreach ($ext in $Extensions) {
            if ($ext -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid extension name '$ext' in $($_.Name)" }
        }
        $ExtensionsArray = if ($Extensions.Count -gt 0) { 'ARRAY[' + (($Extensions | ForEach-Object { "'$_'" }) -join ', ') + ']::text[]' } else { 'ARRAY[]::text[]' }

        # The insight becomes a subquery, so its trailing ';' must go.
        $InsightBody = $InsightBody.TrimEnd() -replace ';\s*$', ''

        $Fill = {
            param([string]$Template)
            $Template.Replace('{InsightId}', $InsightId).Replace('{InsightTitle}', $InsightTitle).Replace('{TopicArea}', $TopicArea).Replace('{Scope}', $Scope).Replace('{RequiresExtensions}', $ExtensionsArray)
        }

        $OutputScriptBuilder += $batchSeparator
        $OutputScriptBuilder += (& $Fill $InsightHeaderTemplate)
        $OutputScriptBuilder += $InsightBody + "`r`n"
        $OutputScriptBuilder += (& $Fill $InsightFooterTemplate)
    }
}

Write-Output "Finalizing output script: $OutputScriptFilePath"

$OutputScriptBuilder += $batchSeparator
$OutputScriptBuilder += [string](Get-Content -Path $TemplateFooterFilePath -Raw)

$OutputScriptBuilder | Out-File $OutputScriptFilePath -Force
