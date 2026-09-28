$namespace = "default"

# Get the first running Camunda pod only
$podName = (kubectl get pods -n $namespace -l app=camunda -o jsonpath="{.items[?(@.status.phase=='Running')].metadata.name}" | ForEach-Object { ($_ -split ' ')[0] })

Write-Host "Monitoring Camunda logs for stress errors from pod: $podName"

kubectl logs -f $podName -n $namespace |
    Tee-Object -FilePath "camunda-errors.log" |
    Select-String -Pattern "OutOfMemoryError",
                           "Job acquisition failed",
                           "RejectedExecutionException",
                           "Connection pool exhausted"
