# check-16kb-arm64-enhanced.ps1
# Comprehensive 16KB page size compliance checker for Android
# Validates PT_LOAD alignment, vaddr/offset consistency, and .note.gnu.property

param(
  [string]$Path,
  [string]$NdkPath,
  [string]$ReportPath,
  [int]$MinAlign = 16384
)

function Get-PtLoadSegments {
  param([string]$SoPath, [string]$ReadobjExe)

  $result = New-Object PSObject -Property @{ 
    Segments = @()
    Error = $null 
    HasAndroidProperty = $false
  }

  $out = & $ReadobjExe --program-headers --sections $SoPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $result.Error = ("llvm-readobj exit code {0}: {1}" -f $LASTEXITCODE, $SoPath)
    return $result
  }

  $reTypeLoad  = '^\s*Type:\s*(?:PT_)?LOAD\b'
  $reAnyType   = '^\s*Type:\s*\S+'
  $reAlignment = '^\s*Align(?:ment)?:\s*(0x[0-9A-Fa-f]+|\d+)'
  $reVAddr     = '^\s*VirtualAddress:\s*(0x[0-9A-Fa-f]+|\d+)'
  $reOffset    = '^\s*Offset:\s*(0x[0-9A-Fa-f]+|\d+)'
  $reAndroidProp = 'note\.android\.property|gnu\.property.*android'

  # Check for .note.gnu.property or similar Android property sections
  $outStr = $out -join "`n"
  if ($outStr -match $reAndroidProp) {
    $result.HasAndroidProperty = $true
  }

  $inLoad = $false
  $currentSegment = $null

  foreach ($line in ($out -split "`n")) {
    $l = $line.TrimEnd()

    if ($l -match $reTypeLoad) { 
      $inLoad = $true
      $currentSegment = @{
        Align = 0
        VAddr = 0
        Offset = 0
      }
      continue 
    }
    
    if ($l -match $reAnyType) { 
      if ($inLoad -and $currentSegment) {
        $result.Segments += $currentSegment
        $currentSegment = $null
      }
      $inLoad = $false
      continue 
    }

    if ($inLoad -and $currentSegment) {
      if ($l -match $reAlignment) {
        $val = $Matches[1]
        if ($val -like '0x*') { $currentSegment.Align = [Convert]::ToInt64($val,16) } 
        else { $currentSegment.Align = [int64]$val }
      }
      elseif ($l -match $reVAddr) {
        $val = $Matches[1]
        if ($val -like '0x*') { $currentSegment.VAddr = [Convert]::ToInt64($val,16) } 
        else { $currentSegment.VAddr = [int64]$val }
      }
      elseif ($l -match $reOffset) {
        $val = $Matches[1]
        if ($val -like '0x*') { $currentSegment.Offset = [Convert]::ToInt64($val,16) } 
        else { $currentSegment.Offset = [int64]$val }
      }
    }
  }

  # Catch last segment if loop ended while in LOAD
  if ($inLoad -and $currentSegment) {
    $result.Segments += $currentSegment
  }

  return $result
}

function Test-SegmentAlignment {
  param([hashtable]$Segment, [int]$MinAlign)
  
  $issues = @()
  
  # Check 1: Alignment value must be >= MinAlign
  if ($Segment.Align -lt $MinAlign) {
    $issues += "p_align ($($Segment.Align)) < $MinAlign"
  }
  
  # Check 2: VirtualAddress must be aligned to p_align
  if ($Segment.Align -gt 0 -and ($Segment.VAddr % $Segment.Align) -ne 0) {
    $issues += "p_vaddr (0x$($Segment.VAddr.ToString('X'))) not aligned to p_align ($($Segment.Align))"
  }
  
  # Check 3: Offset must be aligned to p_align
  if ($Segment.Align -gt 0 -and ($Segment.Offset % $Segment.Align) -ne 0) {
    $issues += "p_offset (0x$($Segment.Offset.ToString('X'))) not aligned to p_align ($($Segment.Align))"
  }
  
  # Check 4: Congruence requirement (p_vaddr % p_align == p_offset % p_align)
  if ($Segment.Align -gt 0) {
    $vaddrMod = $Segment.VAddr % $Segment.Align
    $offsetMod = $Segment.Offset % $Segment.Align
    if ($vaddrMod -ne $offsetMod) {
      $issues += "p_vaddr % p_align (0x$($vaddrMod.ToString('X'))) != p_offset % p_align (0x$($offsetMod.ToString('X')))"
    }
  }
  
  return $issues
}

function Get-SoResult {
  param([string]$SoPath, [string]$ReadobjExe, [int]$MinAlign)

  $r = Get-PtLoadSegments -SoPath $SoPath -ReadobjExe $ReadobjExe
  $segments = $r.Segments

  $ok = $true
  $allIssues = @()
  $segmentDetails = @()

  if ($r.Error) {
    $ok = $false
    $allIssues += $r.Error
  } elseif ($segments.Count -eq 0) {
    $ok = $false
    $allIssues += "No PT_LOAD segments found"
  } else {
    $segNum = 0
    foreach ($seg in $segments) {
      $segNum++
      $issues = Test-SegmentAlignment -Segment $seg -MinAlign $MinAlign
      
      $segInfo = "Segment $segNum - Align:$($seg.Align) VAddr:0x$($seg.VAddr.ToString('X')) Offset:0x$($seg.Offset.ToString('X'))"
      
      if ($issues.Count -gt 0) {
        $ok = $false
        $segInfo += " [FAIL: $($issues -join '; ')]"
        $allIssues += $issues
      } else {
        $segInfo += " [OK]"
      }
      
      $segmentDetails += $segInfo
    }
  }

  return New-Object PSObject -Property @{
    File              = $SoPath
    Segments          = $segments
    SegmentDetails    = $segmentDetails
    HasAndroidProperty = $r.HasAndroidProperty
    OK                = $ok
    Issues            = $allIssues
  }
}

function Find-LlvmReadobj {
  param([string]$NdkRootPath)
  
  $possiblePaths = @(
    "toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readobj.exe",
    "toolchains\llvm\prebuilt\linux-x86_64\bin\llvm-readobj",
    "toolchains\llvm\prebuilt\darwin-x86_64\bin\llvm-readobj"
  )
  
  foreach ($relativePath in $possiblePaths) {
    $fullPath = Join-Path $NdkRootPath $relativePath
    if (Test-Path -LiteralPath $fullPath) {
      return $fullPath
    }
  }
  
  return $null
}

function Get-UserInput {
  param([string]$Prompt, [string]$DefaultValue = "")
  
  if ($DefaultValue) {
    $userInput = Read-Host "$Prompt [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($userInput)) {
      return $DefaultValue
    }
  } else {
    $userInput = Read-Host $Prompt
  }
  
  return $userInput.Trim('"').Trim()
}

# --- Interactive input ---
Write-Host "=== Android NDK 16KB Page Size Checker (Enhanced) ===" -ForegroundColor Cyan
Write-Host ""

$ConfigPath = Join-Path $PSScriptRoot "ndkpath.dat"

if ([string]::IsNullOrWhiteSpace($NdkPath)) {
  if (Test-Path -LiteralPath $ConfigPath) {
    $saved = (Get-Content -LiteralPath $ConfigPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($saved)) { $NdkPath = $saved }
  }
  Write-Host "Please provide the Android NDK root directory path:" -ForegroundColor Yellow
  Write-Host "Example: C:\Users\username\AppData\Local\Android\Sdk\ndk\28.0.12674087" -ForegroundColor Gray
  $NdkPath = Get-UserInput "NDK Root Path" $NdkPath
}

if ([string]::IsNullOrWhiteSpace($NdkPath) -or !(Test-Path -LiteralPath $NdkPath)) {
  Write-Host "Error: NDK path not found or invalid: $NdkPath" -ForegroundColor Red
  exit 1
}

try {
  if ($NdkPath) { Set-Content -LiteralPath $ConfigPath -Value $NdkPath -Encoding UTF8 }
} catch {}

$Readobj = Find-LlvmReadobj -NdkRootPath $NdkPath
if (!$Readobj) {
  Write-Host "Error: llvm-readobj not found in NDK directory." -ForegroundColor Red
  exit 1
}

Write-Host "Found llvm-readobj: $Readobj" -ForegroundColor Green

if ([string]::IsNullOrWhiteSpace($Path)) {
  Write-Host ""
  Write-Host "Please provide the path to your APK, AAR, AAB, or ZIP file:" -ForegroundColor Yellow
  Write-Host "Example: C:\Users\username\Desktop\MyApp.apk" -ForegroundColor Gray
  $Path = Get-UserInput "Archive Path"
}

if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path -LiteralPath $Path)) {
  Write-Host "Error: Archive path not found or invalid: $Path" -ForegroundColor Red
  exit 1
}

Write-Host "Analyzing: $Path" -ForegroundColor Green
Write-Host ""

$AllLines = New-Object System.Collections.ArrayList
$FailList = New-Object System.Collections.ArrayList
$WarningList = New-Object System.Collections.ArrayList

# --- Extract files ---
$TempRoot = $null
$soFiles = @()

if ((Get-Item -LiteralPath $Path).PSIsContainer) {
  $soFiles = Get-ChildItem -Recurse -Path $Path -Filter *.so | Where-Object { $_.FullName -match "arm64-v8a" } | Select-Object -ExpandProperty FullName
} else {
  $ext = [IO.Path]::GetExtension($Path).ToLower()
  if ($ext -eq ".so") {
    if ($Path -match "arm64-v8a") { $soFiles = ,(Resolve-Path -LiteralPath $Path).Path }
  } elseif ($ext -in @(".aar",".apk",".aab",".zip")) {
    Write-Host "Extracting archive..." -ForegroundColor Cyan
    $TempRoot = Join-Path $env:TEMP ("check16kb_" + (Get-Random))
    New-Item -ItemType Directory -Path $TempRoot | Out-Null
    $ZipCopy = Join-Path $TempRoot "archive.zip"
    Copy-Item -LiteralPath $Path -Destination $ZipCopy -Force
    Expand-Archive -LiteralPath $ZipCopy -DestinationPath $TempRoot -Force
    $soFiles = Get-ChildItem -Recurse -Path $TempRoot -Filter *.so | Where-Object { $_.FullName -match "arm64-v8a" } | Select-Object -ExpandProperty FullName
  } else {
    throw ("Unsupported extension: {0}" -f $ext)
  }
}

if (!$soFiles -or $soFiles.Count -eq 0) {
  if ($TempRoot) { Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue }
  Write-Host "No .so files found in arm64-v8a folder." -ForegroundColor Yellow
  exit 0
}

Write-Host "Found $($soFiles.Count) .so file(s) in arm64-v8a folder" -ForegroundColor Cyan
Write-Host ""

# --- Analysis ---
foreach ($so in $soFiles) {
  $fileName = Split-Path $so -Leaf
  Write-Host "Checking: $fileName" -ForegroundColor Gray
  
  $res = Get-SoResult -SoPath $so -ReadobjExe $Readobj -MinAlign $MinAlign

  [void]$AllLines.Add("=" * 80)
  [void]$AllLines.Add("File: $($res.File)")
  [void]$AllLines.Add("")
  
  if ($res.SegmentDetails) {
    [void]$AllLines.Add("PT_LOAD Segments:")
    foreach ($detail in $res.SegmentDetails) {
      [void]$AllLines.Add("  $detail")
    }
  }
  
  [void]$AllLines.Add("")
  [void]$AllLines.Add("Android Property Note: $(if($res.HasAndroidProperty){'Found'}else{'Not found'})")
  
  if (!$res.HasAndroidProperty) {
    [void]$WarningList.Add($res.File)
    Write-Host "  WARNING: No .note.gnu.property section found (may indicate old NDK)" -ForegroundColor Yellow
  }
  
  if ($res.OK) {
    [void]$AllLines.Add("Result: PASS - All segments properly aligned")
    Write-Host "  PASS - All segments properly aligned" -ForegroundColor Green
  } else {
    [void]$AllLines.Add("Result: FAIL")
    foreach ($issue in $res.Issues) {
      [void]$AllLines.Add("  - $issue")
    }
    [void]$FailList.Add($res.File)
    Write-Host "  FAIL - See details below:" -ForegroundColor Red
    foreach ($issue in $res.Issues) {
      Write-Host "    - $issue" -ForegroundColor Red
    }
  }
  
  [void]$AllLines.Add("")
  Write-Host ""
}

# --- Cleanup ---
if ($TempRoot) { Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue }
if ($ReportPath) { $AllLines | Out-File -FilePath $ReportPath -Encoding UTF8 }

# --- Final output ---
Write-Host ""
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "FINAL RESULT" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan

if ($FailList.Count -eq 0) {
  Write-Host "SUCCESS: All .so files pass 16KB alignment checks" -ForegroundColor Green
  
  if ($WarningList.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNINGS: $($WarningList.Count) file(s) missing Android property notes:" -ForegroundColor Yellow
    $WarningList | ForEach-Object { Write-Host "  - $(Split-Path $_ -Leaf)" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "These libraries may still work but were likely built with older NDK versions." -ForegroundColor Yellow
    Write-Host "Consider updating to NDK 27+ and recompiling for full 16KB compatibility." -ForegroundColor Yellow
  }
  
  if ($ReportPath) { Write-Host "`nReport saved to: $ReportPath" }
  exit 0
} else {
  Write-Host "FAILED: $($FailList.Count) non-compliant file(s):" -ForegroundColor Red
  $FailList | ForEach-Object { Write-Host "  - $(Split-Path $_ -Leaf)" -ForegroundColor Red }
  
  if ($ReportPath) { Write-Host "`nComplete report at: $ReportPath" }
  
  Write-Host ""
  Write-Host "Required fixes:" -ForegroundColor Yellow
  Write-Host "1. Update to NDK 27+ which has proper 16KB alignment support" -ForegroundColor Yellow
  Write-Host "2. Add -Wl,-z,max-page-size=16384 to your linker flags" -ForegroundColor Yellow
  Write-Host "3. Recompile all native libraries" -ForegroundColor Yellow
  Write-Host "4. Contact third-party library vendors for 16KB-compatible versions" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "For gradle builds, add to build.gradle:" -ForegroundColor Cyan
  Write-Host "android.defaultConfig.ndk.abiFilters 'arm64-v8a'" -ForegroundColor Gray
  Write-Host "android.defaultConfig.externalNativeBuild.cmake.arguments '-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON'" -ForegroundColor Gray
  
  exit 2
}