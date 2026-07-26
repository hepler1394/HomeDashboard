# ============================================================================
# HomeDashboard - Setup Startup Task
# Creates a Windows scheduled task to launch the agent at system startup
# ============================================================================

$ErrorActionPreference = "Stop"

# Task configuration
$AgentScript = "C:\ProgramData\HomeNetDashboard\agent\homedash-agent.ps1"
$TaskName = "HomeDashboardStartup"

# Verify the agent script exists
if (-not (Test-Path $AgentScript)) {
    Write-Host "ERROR: Agent script not found at $AgentScript" -ForegroundColor Red
    Write-Host "Run bootstrap.ps1 first to enroll this PC." -ForegroundColor Yellow
    exit 1
}

Write-Host "Setting up scheduled task for HomeDashboard startup..." -ForegroundColor Cyan

# Create the action: run the PowerShell script hidden
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$AgentScript"""

# Create the trigger: at system startup with 30-second delay
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = "PT30S"

# Create the settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

# Register the task (will run as current user)
try {
    # Remove existing task if it exists
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Milliseconds 500

    # Register the new task
    $task = Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description "Starts HomeDashboard agent at system startup"

    Write-Host "✓ Scheduled task created successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "Task Details:" -ForegroundColor Cyan
    Write-Host "  Name: $($task.TaskName)"
    Write-Host "  State: $($task.State)"
    Write-Host "  Trigger: System startup (30s delay)"
    Write-Host "  Script: $AgentScript"
    Write-Host ""
    Write-Host "The agent will now start automatically when your computer boots." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to create scheduled task" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
