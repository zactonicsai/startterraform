<#
    render.ps1 - replaces @@TOKEN@@ placeholders with environment variables.

    Windows has no sed, so the .bat scripts use this instead.

    It also forces Unix (LF) line endings on the output. This matters a lot:
    EC2 user-data with Windows CRLF line endings fails on Amazon Linux with
    confusing "$'\r': command not found" errors.

    Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File render.ps1 `
        -In template.tmpl -Out out.sh [-Base64From file]

    -Base64From makes the token @@USER_DATA_B64@@ available, set to the
    base64 encoding of that file (used when building launch-template JSON).
#>
param(
    [Parameter(Mandatory=$true)][string]$In,
    [Parameter(Mandatory=$true)][string]$Out,
    [string]$Base64From = ""
)

$ErrorActionPreference = "Stop"

$extra = @{}
if ($Base64From -ne "") {
    if (-not (Test-Path -LiteralPath $Base64From)) {
        throw "Base64From file not found: $Base64From"
    }
    $extra["USER_DATA_B64"] =
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $Base64From)))
}

$text = Get-Content -Raw -LiteralPath $In

$missing = New-Object System.Collections.Generic.List[string]

$rendered = [regex]::Replace($text, '@@([A-Za-z0-9_]+)@@', {
    param($m)
    $name = $m.Groups[1].Value
    if ($extra.ContainsKey($name)) { return $extra[$name] }
    $val = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrEmpty($val)) {
        $missing.Add($name) | Out-Null
        return ""
    }
    return $val
})

if ($missing.Count -gt 0) {
    throw ("Unset variables referenced by ${In}: " + (($missing | Select-Object -Unique) -join ", "))
}

# Force LF endings and write UTF-8 with no byte-order mark
$rendered = $rendered -replace "`r`n", "`n"
[IO.File]::WriteAllText($Out, $rendered, (New-Object Text.UTF8Encoding $false))

Write-Host "  [ok] rendered $Out"
