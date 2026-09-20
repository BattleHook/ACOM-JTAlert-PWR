<#
Update the SCRIPT_VERSION constant in ACOM-JTAlert-PWR.ahk using Git metadata.

Usage:
  .\update-version.ps1      # updates ACOM-JTAlert-PWR.ahk in-place

The script uses `git describe --tags --dirty --always` when available,
falling back to short commit id. If the working tree is dirty the string
will contain "-dirty" as returned by git.
#>

$repoRoot = $PSScriptRoot
Set-Location $repoRoot

function Get-GitVersion {
	try {
		$desc = git describe --tags --dirty --always 2>$null
		if ($desc) { return $desc.Trim() }
	} catch { }
	try {
		$sha = git rev-parse --short HEAD 2>$null
		if ($sha) { return "g$($sha.Trim())" }
	} catch { }
	return "v0.0.0"
}

$version = Get-GitVersion

$ahkPath = Join-Path $repoRoot 'ACOM-JTAlert-PWR.ahk'
if (-not (Test-Path $ahkPath)) {
	Write-Error "ACOM-JTAlert-PWR.ahk not found in $repoRoot"
	exit 1
}

$content = Get-Content -Raw -LiteralPath $ahkPath

if ($content -match 'SCRIPT_VERSION\s*:=\s*"[^"]*"') {
	$new = $content -replace 'SCRIPT_VERSION\s*:=\s*"[^"]*"', "SCRIPT_VERSION := `"$version`""
} else {
	# Insert after DEBUG line if present, otherwise prepend
	if ($content -match 'DEBUG\s*:=') {
		$new = $content -replace '(DEBUG\s*:=.*\r?\n)', "$1; Script version (updated by update-version.ps1). Default placeholder.`r`nSCRIPT_VERSION := `"$version`"`r`n"
	} else {
		$new = "SCRIPT_VERSION := `"$version`"`r`n" + $content
	}
}

Set-Content -LiteralPath $ahkPath -Value $new -Encoding UTF8
Write-Host "Updated ACOM-JTAlert-PWR.ahk to version: $version"

# Optionally create a versioned copy (uncomment if you want):
# $copyPath = Join-Path $repoRoot ("ACOM-JTAlert-PWR_$version.ahk")
# Copy-Item -LiteralPath $ahkPath -Destination $copyPath -Force
# Write-Host "Wrote versioned copy: $copyPath"
