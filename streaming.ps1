$rules = Get-Content .\rules.json -Raw -Encoding utf8 | ConvertFrom-Json
$prompt = $rules.llm.prompt

$containerHash = ($rules.container | ConvertTo-Json -Compress).GetHashCode().ToString()
$storedHash = if (Test-Path .\.container-hash) { Get-Content .\.container-hash -Raw } else { "" }

if ($containerHash -ne $storedHash) {
    Write-Host "Container settings changed, restarting..." -ForegroundColor Yellow
    docker stop llama-mistral 2>$null
    docker rm llama-mistral 2>$null
    $containerHash | Out-File -FilePath .\.container-hash -NoNewline
}

$running = docker ps --format "{{.Names}}" | Select-String "llama-mistral"
if (-not $running) {
    docker run -d `
        --name llama-mistral `
        --cpus="$($rules.container.cpus)" `
        -p 8080:8080 `
        -v $PWD\models:/models `
        yusiwen/llama.cpp:latest `
        /llama.cpp/llama-server `
        -m /models/mistral-7b-q4.gguf `
        --host 0.0.0.0 `
        --port 8080 `
        --threads $($rules.container.threads) `
        --threads-batch $($rules.container.threads_batch) `
        --ctx-size $($rules.container.ctx_size) `
        --batch-size $($rules.container.batch_size) `
        -np $($rules.container.n_parallel) `
        --mlock `
        --no-mmap
}

# Ждём готовности сервера с анимацией
Write-Host "Waiting for server" -NoNewline -ForegroundColor Yellow
$wait = 2
$maxWait = 60
$elapsed = 0
$spinner = @('|', '/', '-', '\')
$spinnerIndex = 0

while ($elapsed -lt $maxWait) {
    try {
        $test = Invoke-RestMethod -Uri http://127.0.0.1:8080/health -Method Get -TimeoutSec 2
        if ($test.status -eq "ok") {
            Write-Host "`rServer is ready!                    " -ForegroundColor Green
            break
        }
    } catch {}
    
    Write-Host "`r$($spinner[$spinnerIndex]) Loading model... ($elapsed s)" -NoNewline -ForegroundColor Yellow
    $spinnerIndex = ($spinnerIndex + 1) % $spinner.Length
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

if ($elapsed -ge $maxWait) {
    Write-Host "`rServer failed to start within $maxWait seconds" -ForegroundColor Red
    exit 1
}

# Формируем тело запроса
$body = [ordered]@{
    messages = @(@{role = "user"; content = $prompt})
}

foreach ($prop in $rules.llm.PSObject.Properties) {
    if ($prop.Name -ne "prompt") {
        $body[$prop.Name] = $prop.Value
    }
}

$bodyJson = $body | ConvertTo-Json -Depth 3 -Compress

Write-Host "`nStreaming response:`n" -ForegroundColor Cyan

# Отправляем запрос с потоковой передачей
$fullResponse = ""
$allChoices = @{}
$responseChoices = @()

try {
    $webRequest = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:8080/v1/chat/completions")
    $webRequest.Method = "POST"
    $webRequest.ContentType = "application/json"
    $webRequest.Accept = "text/event-stream"
    $webRequest.Timeout = 300000  # 5 минут таймаут
    
    # Отправляем тело запроса
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)
    $webRequest.ContentLength = $bodyBytes.Length
    $requestStream = $webRequest.GetRequestStream()
    $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
    $requestStream.Close()
    
    # Получаем ответ
    $response = $webRequest.GetResponse()
    $responseStream = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8)
    
    Write-Host ("=" * 60)
    
    # Читаем SSE поток
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        
        if ($line.StartsWith("data: ")) {
            $jsonData = $line.Substring(6)
            
            if ($jsonData -eq "[DONE]") {
                break
            }
            
            try {
                $chunk = $jsonData | ConvertFrom-Json
                
                foreach ($choice in $chunk.choices) {
                    $choiceIndex = $choice.index
                    
                    if (-not $allChoices.ContainsKey($choiceIndex)) {
                        $allChoices[$choiceIndex] = @{
                            index = $choiceIndex
                            content = ""
                            finish_reason = $null
                        }
                    }
                    
                    if ($choice.delta.content) {
                        $allChoices[$choiceIndex].content += $choice.delta.content
                        if ($choiceIndex -eq 0) {
                            Write-Host $choice.delta.content -NoNewline
                        }
                    }
                    
                    if ($choice.finish_reason) {
                        $allChoices[$choiceIndex].finish_reason = $choice.finish_reason
                    }
                }
                
                $fullResponse += $jsonData + "`n"
            } catch {
                Write-Host "Error parsing chunk: $_" -ForegroundColor DarkYellow
            }
        }
    }
    
    $reader.Close()
    $responseStream.Close()
    $response.Close()
    
} catch [System.Net.WebException] {
    if ($_.Exception.Response) {
        $errorStream = $_.Exception.Response.GetResponseStream()
        $errorReader = New-Object System.IO.StreamReader($errorStream)
        $errorBody = $errorReader.ReadToEnd()
        Write-Host "`nAPI Error: $errorBody" -ForegroundColor Red
        $errorReader.Close()
        $errorStream.Close()
    } else {
        Write-Host "`nConnection Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host ("=" * 60)

# Сохраняем ответы
$replies = @()
foreach ($choiceData in $allChoices.Values | Sort-Object index) {
    $replies += "--- Response $($choiceData.index + 1) ---"
    $replies += $choiceData.content
    $replies += ""
    
    $responseChoices += @{
        index = $choiceData.index
        message = @{
            role = "assistant"
            content = $choiceData.content
        }
        finish_reason = $choiceData.finish_reason
    }
}

# Сохраняем в replies.txt
$replies -join "`n" | Out-File -FilePath .\replies.txt -Encoding utf8

Write-Host "`nDone! Check replies.txt" -ForegroundColor Green
Write-Host "Total choices generated: $($allChoices.Count)" -ForegroundColor Cyan