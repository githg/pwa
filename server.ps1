function Utf8NoBom($Content, $Path) {
    $MyEncoder = New-Object System.Text.UTF8Encoding($False)
    [System.IO.File]::WriteAllLines($Path, $Content, $MyEncoder)
}

function SafeConvertToJson($InputObject) {
    if ($null -eq $InputObject) {
        return "[]"
    }
    if ($InputObject -is [array] -or $InputObject -is [System.Collections.IList]) {
        $cleanList = @()
        foreach ($item in $InputObject) {
            $cleanList += $item
        }
        return ConvertTo-Json $cleanList -Depth 100 -Compress
    }
    return ConvertTo-Json $InputObject -Depth 100 -Compress
}

# CONFIGURATION - Insert your Google Apps Script Web App URL here:
$gasUrl = "https://script.google.com/macros/s/AKfycbxu_xJtq3VWTCtwu9erZONgU4evkPLpSYWnmMgo-1mHA_Bl63gvZYKvAwiNTJjEIlXufA/exec"

$port = 8080
$ipAddress = [System.Net.IPAddress]::Any
$listener = New-Object System.Net.Sockets.TcpListener($ipAddress, $port)

$dbFile = Join-Path "c:\Users\b\Documents\AG app 1" "entries.json"
if (-not (Test-Path $dbFile)) {
    Utf8NoBom -Content "[]" -Path $dbFile
}
$eodFile = Join-Path "c:\Users\b\Documents\AG app 1" "eod_closings.json"
if (-not (Test-Path $eodFile)) {
    Utf8NoBom -Content "[]" -Path $eodFile
}
$permFile = Join-Path "c:\Users\b\Documents\AG app 1" "counter_permissions.json"
if (-not (Test-Path $permFile)) {
    Utf8NoBom -Content '{"0":true,"1":true,"2":true,"3":true,"4":true,"5":true}' -Path $permFile
}

$syncLock = New-Object System.Object

# Background Sync Thread Script
$syncScript = {
    param($dbFile, $eodFile, $gasUrl)
    
    function Utf8NoBom($Content, $Path) {
        $MyEncoder = New-Object System.Text.UTF8Encoding($False)
        [System.IO.File]::WriteAllLines($Path, $Content, $MyEncoder)
    }
    
    function SafeConvertToJson($InputObject) {
        if ($null -eq $InputObject) { return "[]" }
        $cleanList = @()
        foreach ($item in $InputObject) { $cleanList += $item }
        return ConvertTo-Json $cleanList -Depth 100 -Compress
    }
    
    while ($true) {
        Start-Sleep -Seconds 10
        if (-not $gasUrl -or $gasUrl -eq "YOUR_WEB_APP_URL" -or $gasUrl.Trim() -eq "") {
            continue
        }
        
        # 1. Sync entries
        try {
            if (Test-Path $dbFile) {
                $json = [System.IO.File]::ReadAllText($dbFile)
                $allEntries = @(ConvertFrom-Json $json -ErrorAction SilentlyContinue)
                if ($null -eq $allEntries) { $allEntries = @() }
                $entriesToSync = @($allEntries | Where-Object { $_.syncedToGas -ne $true })
                
                if ($entriesToSync.Count -gt 0 -and $null -ne $entriesToSync[0]) {
                    $successIds = @()
                    foreach ($entry in $entriesToSync) {
                        if ($null -eq $entry) { continue }
                        try {
                            $payload = @{
                                action  = "SYNC_ENTRIES"
                                payload = @{ data = $entry }
                            }
                            $jsonPayload = ConvertTo-Json $payload -Depth 100 -Compress
                            $resp = Invoke-RestMethod -Uri $gasUrl -Method Post -Body $jsonPayload -ContentType "application/json" -TimeoutSec 15
                            if ($resp.status -eq "success") {
                                $successIds += $entry.id
                            }
                        } catch { }
                    }
                    
                    if ($successIds.Count -gt 0) {
                        # Re-read, mark synced, write back
                        $json2 = [System.IO.File]::ReadAllText($dbFile)
                        $currEntries = @(ConvertFrom-Json $json2 -ErrorAction SilentlyContinue)
                        if ($null -ne $currEntries) {
                            foreach ($entry in $currEntries) {
                                if ($null -ne $entry -and $successIds -contains $entry.id) {
                                    $entry | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $true -Force
                                }
                            }
                            $jsonOut = SafeConvertToJson $currEntries
                            Utf8NoBom -Content $jsonOut -Path $dbFile
                        }
                    }
                }
            }
        } catch { }
        
        # 2. Sync EOD closures
        try {
            if (Test-Path $eodFile) {
                $json = [System.IO.File]::ReadAllText($eodFile)
                $allClosures = @(ConvertFrom-Json $json -ErrorAction SilentlyContinue)
                if ($null -eq $allClosures) { $allClosures = @() }
                $closuresToSync = @($allClosures | Where-Object { $_.syncedToGas -ne $true })
                
                if ($closuresToSync.Count -gt 0 -and $null -ne $closuresToSync[0]) {
                    # Fetch entries for counter summaries
                    $dbList = @()
                    if (Test-Path $dbFile) {
                        $djson = [System.IO.File]::ReadAllText($dbFile)
                        $dbList = @(ConvertFrom-Json $djson -ErrorAction SilentlyContinue)
                        if ($null -eq $dbList) { $dbList = @() }
                    }
                    
                    $successDates = @()
                    foreach ($closure in $closuresToSync) {
                        if ($null -eq $closure) { continue }
                        try {
                            $expected = $closure.expected
                            $actual = $closure.actual
                            $denoms = $closure.denoms
                            
                            $ic500 = if ($denoms.ic500) { [double]$denoms.ic500 } else { 0 }
                            $n1000 = if ($denoms.n1000) { [double]$denoms.n1000 } else { 0 }
                            $n500 = if ($denoms.n500) { [double]$denoms.n500 } else { 0 }
                            $n100 = if ($denoms.n100) { [double]$denoms.n100 } else { 0 }
                            $n50 = if ($denoms.n50) { [double]$denoms.n50 } else { 0 }
                            $n20 = if ($denoms.n20) { [double]$denoms.n20 } else { 0 }
                            $n10 = if ($denoms.n10) { [double]$denoms.n10 } else { 0 }
                            $n5 = if ($denoms.n5) { [double]$denoms.n5 } else { 0 }
                            
                            $actualTotalCash = ($ic500 * 1.6) + ($n1000 * 1000) + ($n500 * 500) + ($n100 * 100) + ($n50 * 50) + ($n20 * 20) + ($n10 * 10) + ($n5 * 5)
                            $actualTotalC = $actualTotalCash - $closure.openingCash
                            
                            $expectedTotalC = $expected.sales_c + $expected.coll_cash
                            $expectedTotalQr = $expected.sales_qr + $expected.online_qr + $expected.coll_qr
                            $expectedTotalIps = $expected.sales_ips + $expected.coll_ips
                            
                            $reconcileRows = @(
                                @{ particular = "Total C"; inExpected = $expectedTotalC; outActual = $actualTotalC; variance = $actualTotalC - $expectedTotalC },
                                @{ particular = "Total QR"; inExpected = $expectedTotalQr; outActual = [double]$actual.total_qr; variance = [double]$actual.total_qr - $expectedTotalQr },
                                @{ particular = "Total IPS/EBL"; inExpected = $expectedTotalIps; outActual = [double]$actual.total_ips; variance = [double]$actual.total_ips - $expectedTotalIps },
                                @{ particular = "ESewa"; inExpected = [double]$expected.esewa; outActual = [double]$actual.esewa; variance = [double]$actual.esewa - [double]$expected.esewa },
                                @{ particular = "POS"; inExpected = [double]$expected.pos; outActual = [double]$actual.pos; variance = [double]$actual.pos - [double]$expected.pos },
                                @{ particular = "Cheque"; inExpected = [double]$expected.cheque; outActual = [double]$actual.cheque; variance = [double]$actual.cheque - [double]$expected.cheque },
                                @{ particular = "Credit"; inExpected = [double]$expected.credit; outActual = [double]$actual.credit; variance = [double]$actual.credit - [double]$expected.credit }
                            )

                            $activeEntries = @($dbList | Where-Object { $_.isVoid -ne $true })
                            $counterGroups = @{}
                            foreach ($e in $activeEntries) {
                                if ($null -eq $e) { continue }
                                $cid = $e.counterId
                                if (-not $counterGroups.ContainsKey($cid)) {
                                    $counterGroups[$cid] = @()
                                }
                                $counterGroups[$cid] += $e
                            }
                            
                            $counterSummaries = @()
                            foreach ($cid in $counterGroups.Keys) {
                                $cashSum = 0; $qrSum = 0; $salesSum = 0
                                foreach ($e in $counterGroups[$cid]) {
                                    $cashSum += $e.cash
                                    $qrSum += $e.qr
                                    $salesSum += $e.totalIn + $e.totalCredit
                                }
                                $counterSummaries += @{
                                    counterName = "Counter " + $cid
                                    totalCash   = $cashSum
                                    totalQr     = $qrSum
                                    totalSales  = $salesSum
                                }
                            }

                            $payload = @{
                                action  = "EOD_CLOSING"
                                payload = @{
                                    data = @{
                                        date             = $closure.date
                                        reconcileRows    = $reconcileRows
                                        counterSummaries = $counterSummaries
                                    }
                                }
                            }

                            $jsonPayload = ConvertTo-Json $payload -Depth 100 -Compress
                            $resp = Invoke-RestMethod -Uri $gasUrl -Method Post -Body $jsonPayload -ContentType "application/json" -TimeoutSec 30
                            if ($resp.status -eq "success") {
                                $successDates += $closure.date
                            }
                        } catch { }
                    }
                    
                    if ($successDates.Count -gt 0) {
                        $json2 = [System.IO.File]::ReadAllText($eodFile)
                        $currClosures = @(ConvertFrom-Json $json2 -ErrorAction SilentlyContinue)
                        if ($null -ne $currClosures) {
                            foreach ($closure in $currClosures) {
                                if ($null -ne $closure -and $successDates -contains $closure.date) {
                                    $closure | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $true -Force
                                }
                            }
                            $jsonOut = SafeConvertToJson $currClosures
                            Utf8NoBom -Content $jsonOut -Path $eodFile
                        }
                    }
                }
            }
        } catch { }
    }
}

try {
    # Start background sync runspace thread
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript($syncScript)
    [void]$powershell.AddArgument($dbFile)
    [void]$powershell.AddArgument($eodFile)
    [void]$powershell.AddArgument($gasUrl)
    $syncJob = $powershell.BeginInvoke()

    $listener.Start()
    Write-Output "HTTP server with Sync API started successfully on port $port."
}
catch {
    Write-Error "Failed to start TCP listener: $_"
    exit 1
}

while ($true) {
    try {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream)
            
            $requestLine = $reader.ReadLine()
            if ($null -ne $requestLine) {
                $contentLength = 0
                # Read and consume all request headers, extract Content-Length
                while ($true) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line -or $line.Trim() -eq "") {
                        break
                    }
                    if ($line -match "Content-Length:\s*(\d+)") {
                        $contentLength = [int]$Matches[1]
                    }
                }

                # Read body fully in a loop until Content-Length is reached
                $body = ""
                if ($contentLength -gt 0) {
                    $charBuffer = New-Object char[] $contentLength
                    $totalRead = 0
                    while ($totalRead -lt $contentLength) {
                        $readCount = $reader.Read($charBuffer, $totalRead, $contentLength - $totalRead)
                        if ($readCount -le 0) {
                            break
                        }
                        $totalRead += $readCount
                    }
                    $body = [string]::new($charBuffer, 0, $totalRead)
                }

                $parts = $requestLine.Split(' ')
                if ($parts.Length -ge 2) {
                    $method = $parts[0]
                    $urlPath = $parts[1]
                    if ($urlPath.Contains("?")) {
                        $urlPath = $urlPath.Substring(0, $urlPath.IndexOf("?"))
                    }
                    
                    # Handle CORS preflight OPTIONS requests
                    if ($method -eq "OPTIONS") {
                        $header = "HTTP/1.1 204 No Content`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Flush()
                        $client.Close()
                        continue
                    }

                    # API ENDPOINTS FOR SYNCING
                    if ($urlPath -eq "/api/entries" -and $method -eq "GET") {
                        $json = [System.IO.File]::ReadAllText($dbFile)
                        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($responseBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($responseBytes, 0, $responseBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/eod-closings" -and $method -eq "GET") {
                        $json = [System.IO.File]::ReadAllText($eodFile)
                        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($responseBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($responseBytes, 0, $responseBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/eod-closings" -and $method -eq "POST") {
                        [System.Threading.Monitor]::Enter($syncLock)
                        try {
                            $jsonText = [System.IO.File]::ReadAllText($eodFile)
                            $eodList = ConvertFrom-Json $jsonText -ErrorAction SilentlyContinue
                            if ($null -eq $eodList) { $eodList = @() }
                            if (-not ($eodList -is [array])) { $eodList = @($eodList) }

                            $newClosure = ConvertFrom-Json $body
                            if ($null -ne $newClosure) {
                                $newClosure | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $false -Force
                            }
                            
                            $updatedList = @()
                            $found = $false
                            foreach ($item in $eodList) {
                                if ($item.date -eq $newClosure.date) {
                                    $updatedList += $newClosure
                                    $found = $true
                                }
                                else {
                                    $updatedList += $item
                                }
                            }
                            if (-not $found) {
                                $updatedList += $newClosure
                            }

                            $jsonOut = SafeConvertToJson $updatedList
                            Utf8NoBom -Content $jsonOut -Path $eodFile
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncLock)
                        }

                        $resp = '{"status":"saved"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/entries" -and $method -eq "POST") {
                        [System.Threading.Monitor]::Enter($syncLock)
                        try {
                            # Load database
                            $jsonText = [System.IO.File]::ReadAllText($dbFile)
                            $dbList = ConvertFrom-Json $jsonText -ErrorAction SilentlyContinue
                            if ($null -eq $dbList) { $dbList = @() }
                            if (-not ($dbList -is [array])) { $dbList = @($dbList) }

                            # Parse incoming entry
                            $newEntry = ConvertFrom-Json $body
                            if ($null -ne $newEntry) {
                                $newEntry | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $false -Force
                                if (-not $newEntry.date) {
                                    $newEntry | Add-Member -NotePropertyName "date" -NotePropertyValue (Get-Date -Format "yyyy-MM-dd") -Force
                                }
                            }
                            
                            # Merge entry (replace if existing, else add)
                            $updatedList = @()
                            $found = $false
                            foreach ($item in $dbList) {
                                if ($item.id -eq $newEntry.id) {
                                    $updatedList += $newEntry
                                    $found = $true
                                }
                                else {
                                    $updatedList += $item
                                }
                            }
                            if (-not $found) {
                                $updatedList += $newEntry
                            }

                            # Save database
                            $jsonOut = SafeConvertToJson $updatedList
                            Utf8NoBom -Content $jsonOut -Path $dbFile
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncLock)
                        }

                        $resp = '{"status":"ok"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/archive" -and $method -eq "POST") {
                        $params = ConvertFrom-Json $body
                        $cid = $params.counterId
                        $remarks = $params.remarks
                        
                        [System.Threading.Monitor]::Enter($syncLock)
                        try {
                            $jsonText = [System.IO.File]::ReadAllText($dbFile)
                            $dbList = ConvertFrom-Json $jsonText
                            if ($null -eq $dbList) { $dbList = @() }
                            if (-not ($dbList -is [array])) { $dbList = @($dbList) }

                            $closureId = "close_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                            $closureTimestamp = (Get-Date).ToString()

                            foreach ($item in $dbList) {
                                if ($item.counterId -eq $cid -and $item.sessionStatus -ne 'closed') {
                                    # Use Add-Member to dynamically append and force properties on PSCustomObject
                                    $item | Add-Member -NotePropertyName "sessionStatus" -NotePropertyValue "closed" -Force
                                    $item | Add-Member -NotePropertyName "closureId" -NotePropertyValue $closureId -Force
                                    $item | Add-Member -NotePropertyName "closureTimestamp" -NotePropertyValue $closureTimestamp -Force
                                    $item | Add-Member -NotePropertyName "closureRemarks" -NotePropertyValue $remarks -Force
                                    $item | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $false -Force
                                }
                            }

                            $jsonOut = SafeConvertToJson $dbList
                            Utf8NoBom -Content $jsonOut -Path $dbFile
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncLock)
                        }

                        $resp = '{"status":"archived"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/delete" -and $method -eq "POST") {
                        $params = ConvertFrom-Json $body
                        $targetId = $params.id
                        
                        [System.Threading.Monitor]::Enter($syncLock)
                        try {
                            $jsonText = [System.IO.File]::ReadAllText($dbFile)
                            $dbList = ConvertFrom-Json $jsonText
                            if ($null -eq $dbList) { $dbList = @() }
                            if (-not ($dbList -is [array])) { $dbList = @($dbList) }

                            $updatedList = @()
                            foreach ($item in $dbList) {
                                if ($item.id -ne $targetId) {
                                    $updatedList += $item
                                }
                            }

                            $jsonOut = SafeConvertToJson $updatedList
                            Utf8NoBom -Content $jsonOut -Path $dbFile
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncLock)
                        }

                        $resp = '{"status":"deleted"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/counter-permissions" -and $method -eq "GET") {
                        $json = [System.IO.File]::ReadAllText($permFile)
                        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($responseBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($responseBytes, 0, $responseBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/counter-permissions" -and $method -eq "POST") {
                        try {
                            $payload = ConvertFrom-Json $body
                            $jsonText = [System.IO.File]::ReadAllText($permFile)
                            $perms = ConvertFrom-Json $jsonText
                            $cid = [string]($payload.counterId)
                            $enabled = [bool]($payload.enabled)
                            $perms | Add-Member -MemberType NoteProperty -Name $cid -Value $enabled -Force
                            $jsonOut = ConvertTo-Json $perms -Compress
                            Utf8NoBom -Content $jsonOut -Path $permFile
                        } catch {
                            Write-Error "Error updating counter permissions: $_"
                        }
                        $resp = '{"status":"success"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/wipe" -and $method -eq "POST") {
                        [System.Threading.Monitor]::Enter($syncLock)
                        try {
                            Utf8NoBom -Content "[]" -Path $dbFile
                            Utf8NoBom -Content "[]" -Path $eodFile
                            Utf8NoBom -Content '{"0":true,"1":true,"2":true,"3":true,"4":true,"5":true}' -Path $permFile
                        } finally {
                            [System.Threading.Monitor]::Exit($syncLock)
                        }
                        $resp = '{"status":"wiped"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/force-sync" -and $method -eq "POST") {
                        $syncedEntries = 0
                        $syncedClosures = 0
                        $syncErrors = @()
                        
                        if ($gasUrl -and $gasUrl -ne "YOUR_WEB_APP_URL" -and $gasUrl.Trim() -ne "") {
                            # Sync entries
                            try {
                                [System.Threading.Monitor]::Enter($syncLock)
                                try {
                                    $json = [System.IO.File]::ReadAllText($dbFile)
                                } finally {
                                    [System.Threading.Monitor]::Exit($syncLock)
                                }
                                $allEntries = @(ConvertFrom-Json $json -ErrorAction SilentlyContinue)
                                if ($null -eq $allEntries) { $allEntries = @() }
                                $unsynced = @($allEntries | Where-Object { $_.syncedToGas -ne $true })
                                
                                $successIds = @()
                                foreach ($entry in $unsynced) {
                                    if ($null -eq $entry) { continue }
                                    try {
                                        $payload = @{
                                            action  = "SYNC_ENTRIES"
                                            payload = @{ data = $entry }
                                        }
                                        $jp = ConvertTo-Json $payload -Depth 100 -Compress
                                        $r = Invoke-RestMethod -Uri $gasUrl -Method Post -Body $jp -ContentType "application/json" -TimeoutSec 30
                                        if ($r.status -eq "success") {
                                            $successIds += $entry.id
                                            $syncedEntries++
                                        }
                                    } catch {
                                        $syncErrors += "Entry $($entry.id): $_"
                                    }
                                }
                                
                                if ($successIds.Count -gt 0) {
                                    [System.Threading.Monitor]::Enter($syncLock)
                                    try {
                                        $json2 = [System.IO.File]::ReadAllText($dbFile)
                                        $curr = @(ConvertFrom-Json $json2 -ErrorAction SilentlyContinue)
                                        if ($null -ne $curr) {
                                            foreach ($e in $curr) {
                                                if ($null -ne $e -and $successIds -contains $e.id) {
                                                    $e | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $true -Force
                                                }
                                            }
                                            $out = SafeConvertToJson $curr
                                            Utf8NoBom -Content $out -Path $dbFile
                                        }
                                    } finally {
                                        [System.Threading.Monitor]::Exit($syncLock)
                                    }
                                }
                            } catch {
                                $syncErrors += "Entries batch: $_"
                            }
                            
                            # Sync EOD closures
                            try {
                                [System.Threading.Monitor]::Enter($syncLock)
                                try {
                                    $ejson = [System.IO.File]::ReadAllText($eodFile)
                                } finally {
                                    [System.Threading.Monitor]::Exit($syncLock)
                                }
                                $allClosures = @(ConvertFrom-Json $ejson -ErrorAction SilentlyContinue)
                                if ($null -eq $allClosures) { $allClosures = @() }
                                $unsyncedC = @($allClosures | Where-Object { $_.syncedToGas -ne $true })
                                
                                # Read entries for counter summaries
                                [System.Threading.Monitor]::Enter($syncLock)
                                try {
                                    $djson = [System.IO.File]::ReadAllText($dbFile)
                                } finally {
                                    [System.Threading.Monitor]::Exit($syncLock)
                                }
                                $dbList = @(ConvertFrom-Json $djson -ErrorAction SilentlyContinue)
                                if ($null -eq $dbList) { $dbList = @() }
                                
                                $successDates = @()
                                foreach ($closure in $unsyncedC) {
                                    if ($null -eq $closure) { continue }
                                    try {
                                        $expected = $closure.expected
                                        $actual = $closure.actual
                                        $denoms = $closure.denoms
                                        
                                        $ic500 = if ($denoms.ic500) { [double]$denoms.ic500 } else { 0 }
                                        $n1000 = if ($denoms.n1000) { [double]$denoms.n1000 } else { 0 }
                                        $n500 = if ($denoms.n500) { [double]$denoms.n500 } else { 0 }
                                        $n100 = if ($denoms.n100) { [double]$denoms.n100 } else { 0 }
                                        $n50 = if ($denoms.n50) { [double]$denoms.n50 } else { 0 }
                                        $n20 = if ($denoms.n20) { [double]$denoms.n20 } else { 0 }
                                        $n10 = if ($denoms.n10) { [double]$denoms.n10 } else { 0 }
                                        $n5 = if ($denoms.n5) { [double]$denoms.n5 } else { 0 }
                                        
                                        $actualTotalCash = ($ic500 * 1.6) + ($n1000 * 1000) + ($n500 * 500) + ($n100 * 100) + ($n50 * 50) + ($n20 * 20) + ($n10 * 10) + ($n5 * 5)
                                        $actualTotalC = $actualTotalCash - $closure.openingCash
                                        
                                        $expectedTotalC = $expected.sales_c + $expected.coll_cash
                                        $expectedTotalQr = $expected.sales_qr + $expected.online_qr + $expected.coll_qr
                                        $expectedTotalIps = $expected.sales_ips + $expected.coll_ips
                                        
                                        $reconcileRows = @(
                                            @{ particular = "Total C"; inExpected = $expectedTotalC; outActual = $actualTotalC; variance = $actualTotalC - $expectedTotalC },
                                            @{ particular = "Total QR"; inExpected = $expectedTotalQr; outActual = [double]$actual.total_qr; variance = [double]$actual.total_qr - $expectedTotalQr },
                                            @{ particular = "Total IPS/EBL"; inExpected = $expectedTotalIps; outActual = [double]$actual.total_ips; variance = [double]$actual.total_ips - $expectedTotalIps },
                                            @{ particular = "ESewa"; inExpected = [double]$expected.esewa; outActual = [double]$actual.esewa; variance = [double]$actual.esewa - [double]$expected.esewa },
                                            @{ particular = "POS"; inExpected = [double]$expected.pos; outActual = [double]$actual.pos; variance = [double]$actual.pos - [double]$expected.pos },
                                            @{ particular = "Cheque"; inExpected = [double]$expected.cheque; outActual = [double]$actual.cheque; variance = [double]$actual.cheque - [double]$expected.cheque },
                                            @{ particular = "Credit"; inExpected = [double]$expected.credit; outActual = [double]$actual.credit; variance = [double]$actual.credit - [double]$expected.credit }
                                        )

                                        $activeEntries = @($dbList | Where-Object { $_.isVoid -ne $true })
                                        $counterGroups = @{}
                                        foreach ($e in $activeEntries) {
                                            if ($null -eq $e) { continue }
                                            $cid = $e.counterId
                                            if (-not $counterGroups.ContainsKey($cid)) { $counterGroups[$cid] = @() }
                                            $counterGroups[$cid] += $e
                                        }
                                        $counterSummaries = @()
                                        foreach ($cid in $counterGroups.Keys) {
                                            $cashSum = 0; $qrSum = 0; $salesSum = 0
                                            foreach ($e in $counterGroups[$cid]) {
                                                $cashSum += $e.cash; $qrSum += $e.qr; $salesSum += $e.totalIn + $e.totalCredit
                                            }
                                            $counterSummaries += @{ counterName = "Counter " + $cid; totalCash = $cashSum; totalQr = $qrSum; totalSales = $salesSum }
                                        }

                                        $payload = @{
                                            action  = "EOD_CLOSING"
                                            payload = @{ data = @{ date = $closure.date; reconcileRows = $reconcileRows; counterSummaries = $counterSummaries } }
                                        }
                                        $jp = ConvertTo-Json $payload -Depth 100 -Compress
                                        $r = Invoke-RestMethod -Uri $gasUrl -Method Post -Body $jp -ContentType "application/json" -TimeoutSec 30
                                        if ($r.status -eq "success") {
                                            $successDates += $closure.date
                                            $syncedClosures++
                                        }
                                    } catch {
                                        $syncErrors += "EOD $($closure.date): $_"
                                    }
                                }
                                
                                if ($successDates.Count -gt 0) {
                                    [System.Threading.Monitor]::Enter($syncLock)
                                    try {
                                        $ejson2 = [System.IO.File]::ReadAllText($eodFile)
                                        $currC = @(ConvertFrom-Json $ejson2 -ErrorAction SilentlyContinue)
                                        if ($null -ne $currC) {
                                            foreach ($c in $currC) {
                                                if ($null -ne $c -and $successDates -contains $c.date) {
                                                    $c | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $true -Force
                                                }
                                            }
                                            $out = SafeConvertToJson $currC
                                            Utf8NoBom -Content $out -Path $eodFile
                                        }
                                    } finally {
                                        [System.Threading.Monitor]::Exit($syncLock)
                                    }
                                }
                            } catch {
                                $syncErrors += "EOD batch: $_"
                            }
                        } else {
                            $syncErrors += "GAS URL not configured"
                        }
                        
                        $resultObj = @{ status = "done"; syncedEntries = $syncedEntries; syncedClosures = $syncedClosures; errors = $syncErrors }
                        $resp = ConvertTo-Json $resultObj -Depth 10 -Compress
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/load-test-data" -and $method -eq "POST") {
                        $testFile = Join-Path "c:\Users\b\Documents\AG app 1" "test_entries.json"
                        [System.Threading.Monitor]::Enter($syncLock)
                        try {
                            $testData = [System.IO.File]::ReadAllText($testFile)
                            $testList = ConvertFrom-Json $testData -ErrorAction SilentlyContinue
                            if ($null -ne $testList) {
                                if (-not ($testList -is [array])) { $testList = @($testList) }
                                foreach ($entry in $testList) {
                                    $entry | Add-Member -NotePropertyName "syncedToGas" -NotePropertyValue $false -Force
                                    $entry | Add-Member -NotePropertyName "date" -NotePropertyValue "2026-07-12" -Force
                                }
                                $jsonOut = SafeConvertToJson $testList
                                Utf8NoBom -Content $jsonOut -Path $dbFile
                            }
                        } finally {
                            [System.Threading.Monitor]::Exit($syncLock)
                        }
                        $resp = '{"status":"loaded"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    elseif ($urlPath -eq "/api/log" -and $method -eq "POST") {
                        Write-Host "CLIENT ERROR LOG: $body"
                        
                        $resp = '{"status":"logged"}'
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($respBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($respBytes, 0, $respBytes.Length)
                    }
                    else {
                        # Static File Serving
                        if ($urlPath -eq "/" -or $urlPath -eq "") {
                            $urlPath = "/instant_capture_pwa.html"
                        }
                        
                        $filePath = Join-Path "c:\Users\b\Documents\AG app 1" ($urlPath.TrimStart('/'))
                        if (Test-Path $filePath -PathType Leaf) {
                            $bytes = [System.IO.File]::ReadAllBytes($filePath)
                            
                            $contentType = "text/html; charset=utf-8"
                            if ($filePath.EndsWith(".css")) { $contentType = "text/css" }
                            elseif ($filePath.EndsWith(".js")) { $contentType = "application/javascript" }
                            
                            $header = "HTTP/1.1 200 OK`r`nContent-Type: $contentType`r`nContent-Length: $($bytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                            $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
                            
                            $stream.Write($headerBytes, 0, $headerBytes.Length)
                            $stream.Write($bytes, 0, $bytes.Length)
                        }
                        else {
                            $notFound = "HTTP/1.1 404 Not Found`r`nContent-Length: 9`r`nConnection: close`r`n`r`nNot Found"
                            $notFoundBytes = [System.Text.Encoding]::UTF8.GetBytes($notFound)
                            $stream.Write($notFoundBytes, 0, $notFoundBytes.Length)
                        }
                    }
                }
            }
            $stream.Flush()
            $client.Close()
        }
        else {
            Start-Sleep -Milliseconds 20
        }
    }
    catch {
        Write-Warning $_.Exception.Message
    }
}
