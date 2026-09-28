$exePath = "C:\Program Files (x86)\Winrk\winrk.exe"
$url = "http://localhost:8082/engine-rest/process-definition/key/VoteProcess/start"

Write-Host "Running LOW load test..."
& $exePath -t2 -c10 -d10 $url   # 10 seconds

Write-Host "Running MEDIUM load test..."
& $exePath -t4 -c50 -d30 $url   # 30 seconds

Write-Host "Running HIGH load test..."
& $exePath -t8 -c200 -d60 $url  # 60 seconds

Write-Host "Load test completed."
