#Requires -Version 5.1

if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
    if ($env:LOCALAPPDATA -and (Test-Path $env:LOCALAPPDATA)) {
        $env:TEMP = Join-Path $env:LOCALAPPDATA "Temp"
    }
    if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
        if ($PSScriptRoot) {
            $env:TEMP = Join-Path $PSScriptRoot "temp"
        } else {
            $env:TEMP = Join-Path (Get-Location).Path "temp"
        }
    }
}
if (-not (Test-Path $env:TEMP)) {
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
}

function Get-SteamPath {
    $steamPath = $null
    
    $regPath = "HKCU:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "SteamPath" -ErrorAction SilentlyContinue).SteamPath
        if ($steamPath -and (Test-Path $steamPath)) {
            return $steamPath
        }
    }
    
    $regPath = "HKLM:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            return $steamPath
        }
    }
    
    $regPath = "HKLM:\Software\WOW6432Node\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            return $steamPath
        }
    }
    
    return $null
}

function Download-FileWithProgress {
    param(
        [string]$Url,
        [string]$OutFile
    )
    
    try {
        $uri = New-Object System.Uri($Url)
        $uriBuilder = New-Object System.UriBuilder($uri)
        $timestamp = (Get-Date -Format 'yyyyMMddHHmmss')
        if ($uriBuilder.Query) {
            $uriBuilder.Query = $uriBuilder.Query.TrimStart('?') + "&t=" + $timestamp
        } else {
            $uriBuilder.Query = "t=" + $timestamp
        }
        $cacheBustUrl = $uriBuilder.ToString()
        
        $request = [System.Net.HttpWebRequest]::Create($cacheBustUrl)
        $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $request.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
        $request.Headers.Add("Pragma", "no-cache")
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        
        try {
            $response = $request.GetResponse()
        } catch {
            throw "Connection timeout or failed to connect to server"
        }
        
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne 200) {
            $response.Close()
            throw "Server returned status code $statusCode instead of 200"
        }
        
        $totalLength = $response.ContentLength
        if ($totalLength -le 0) {
            $response.Close()
            throw "Server did not return valid content length"
        }
        
        $response.Close()
        
        $request = [System.Net.HttpWebRequest]::Create($cacheBustUrl)
        $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $request.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
        $request.Headers.Add("Pragma", "no-cache")
        $request.Timeout = -1
        $request.ReadWriteTimeout = -1
        
        $response = $null
        try {
            $response = $request.GetResponse()
        } catch {
            throw "Connection failed during download"
        }
        
        try {
            $outDir = Split-Path $OutFile -Parent
            if ($outDir -and -not (Test-Path $outDir)) {
                New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            }
            
            $responseStream = $null
            $targetStream = $null
            $responseStream = $response.GetResponseStream()
            $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $OutFile, Create
            
            $buffer = New-Object byte[] 10KB
            $count = $responseStream.Read($buffer, 0, $buffer.Length)
            $downloadedBytes = $count
            $lastBytesDownloaded = $downloadedBytes
            $lastBytesUpdateTime = Get-Date
            $stuckTimeoutSeconds = 60
            
            while ($count -gt 0) {
                $targetStream.Write($buffer, 0, $count)
                $count = $responseStream.Read($buffer, 0, $buffer.Length)
                $downloadedBytes += $count
                
                $now = Get-Date
                if ($downloadedBytes -gt $lastBytesDownloaded) {
                    $lastBytesDownloaded = $downloadedBytes
                    $lastBytesUpdateTime = $now
                } else {
                    $timeSinceLastBytes = ($now - $lastBytesUpdateTime).TotalSeconds
                    if ($timeSinceLastBytes -ge $stuckTimeoutSeconds) {
                        if (Test-Path $OutFile) {
                            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                        }
                        throw "Download stalled - no data received for $stuckTimeoutSeconds seconds"
                    }
                }
            }
            
            return $true
        } finally {
            if ($targetStream) {
                $targetStream.Close()
            }
            if ($responseStream) {
                $responseStream.Close()
            }
            if ($response) {
                $response.Close()
            }
        }
    } catch {
        throw $_
    }
}

function Download-AndExtractWithFallback {
    param(
        [string]$PrimaryUrl,
        [string]$FallbackUrl,
        [string]$TempZipPath,
        [string]$DestinationPath,
        [string]$Description
    )
    
    $urls = @($PrimaryUrl, $FallbackUrl)
    $lastError = $null
    
    foreach ($url in $urls) {
        $isFallback = ($url -eq $FallbackUrl)
        
        try {
            if (Test-Path $TempZipPath) {
                Remove-Item -Path $TempZipPath -Force -ErrorAction SilentlyContinue
            }
            
            Download-FileWithProgress -Url $url -OutFile $TempZipPath
            
            Expand-ArchiveWithProgress -ZipPath $TempZipPath -DestinationPath $DestinationPath
            
            Remove-Item -Path $TempZipPath -Force -ErrorAction SilentlyContinue
            
            return $true
        } catch {
            $lastError = $_
            $errorMessage = $_.ToString()
            if ($_.Exception -and $_.Exception.Message) {
                $errorMessage = $_.Exception.Message
            }
            
            if ($isFallback) {
                throw "Both primary and fallback downloads failed. Last error: $_"
            } else {
                if ($errorMessage -match "Invalid ZIP|corrupted|End of Central Directory|PK signature|ZIP file|Connection.*failed|timeout|stalled|stuck|failed to connect") {
                    continue
                } else {
                    throw $_
                }
            }
        }
    }
    
    if ($lastError) {
        throw $lastError
    } else {
        throw "Download failed for unknown reason"
    }
}

function Expand-ArchiveWithProgress {
    param(
        [string]$ZipPath,
        [string]$DestinationPath
    )
    
    try {
        if (-not (Test-Path $ZipPath)) {
            throw "ZIP file does not exist"
        }
        
        $zipFileInfo = Get-Item $ZipPath -ErrorAction Stop
        if ($zipFileInfo.Length -eq 0) {
            throw "ZIP file is empty"
        }
        
        $zipStream = $null
        try {
            $zipStream = [System.IO.File]::OpenRead($ZipPath)
            $header = New-Object byte[] 4
            $bytesRead = $zipStream.Read($header, 0, 4)
            
            if ($bytesRead -lt 4 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B) {
                throw "Invalid ZIP file format"
            }
        } finally {
            if ($zipStream) {
                $zipStream.Close()
            }
        }
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        } catch {
            throw "ZIP file is corrupted - download may have been interrupted. Please try again."
        }
        
        try {
            $entries = $zip.Entries
            
            $fileEntries = @()
            foreach ($entry in $entries) {
                if (-not ($entry.FullName.EndsWith('\') -or $entry.FullName.EndsWith('/'))) {
                    $fileEntries += $entry
                }
            }
            $totalFiles = $fileEntries.Count
            if ($totalFiles -eq 0) {
                return $true
            }
            
            foreach ($entry in $entries) {
                $entryPath = Join-Path $DestinationPath $entry.FullName
                
                $entryDir = Split-Path $entryPath -Parent
                if ($entryDir -and -not (Test-Path $entryDir)) {
                    New-Item -ItemType Directory -Path $entryDir -Force | Out-Null
                }
                
                if ($entry.FullName.EndsWith('\') -or $entry.FullName.EndsWith('/')) {
                    continue
                }
                
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryPath, $true)
            }
            
            return $true
        } finally {
            if ($zip) {
                $zip.Dispose()
            }
        }
    } catch {
        throw $_
    }
}

$steamPath = Get-SteamPath
$steamExePath = $null

if (-not $steamPath) {
    throw "Steam installation not found in registry"
}

$steamExePath = Join-Path $steamPath "Steam.exe"

if (-not (Test-Path $steamExePath)) {
    throw "Steam.exe not found at: $steamExePath"
}

$steamProcesses = Get-Process -Name "steam*" -ErrorAction SilentlyContinue
if ($steamProcesses) {
    foreach ($proc in $steamProcesses) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
    Start-Sleep -Seconds 2
}

$steamCfgPath = Join-Path $steamPath "steam.cfg"
if (Test-Path $steamCfgPath) {
    try {
        Remove-Item -Path $steamCfgPath -Force -ErrorAction Stop
    } catch {
    }
}

$steamZipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/latest32bitsteam.zip"
$steamZipFallbackUrl = "http://files.luatools.work/OneOffFiles/latest32bitsteam.zip"
$tempSteamZip = Join-Path $env:TEMP "latest32bitsteam.zip"

try {
    Download-AndExtractWithFallback -PrimaryUrl $steamZipUrl -FallbackUrl $steamZipFallbackUrl -TempZipPath $tempSteamZip -DestinationPath $steamPath -Description "Steam x32 Latest Build"
} catch {
}

$millenniumDll = Join-Path $steamPath "millennium.dll"

if (Test-Path $millenniumDll) {
    $zipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/luatoolsmilleniumbuild.zip"
    $zipFallbackUrl = "http://files.luatools.work/OneOffFiles/luatoolsmilleniumbuild.zip"
    $tempZip = Join-Path $env:TEMP "luatoolsmilleniumbuild.zip"

    try {
        Download-AndExtractWithFallback -PrimaryUrl $zipUrl -FallbackUrl $zipFallbackUrl -TempZipPath $tempZip -DestinationPath $steamPath -Description "Millennium build"
    } catch {
    }
}

$steamCfgPath = Join-Path $steamPath "steam.cfg"

$cfgContent = "BootStrapperInhibitAll=enable`nBootStrapperForceSelfUpdate=disable"
Set-Content -Path $steamCfgPath -Value $cfgContent -Force

$arguments = @("-clearbeta")

try {
    $process = Start-Process -FilePath $steamExePath -ArgumentList $arguments -PassThru -WindowStyle Hidden
} catch {
    throw "Failed to start Steam: $_"
}
