param(
    [string]$GodotExecutable = ""
)

$ErrorActionPreference = "Stop"
$hostRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = (Resolve-Path (Join-Path $hostRoot "..\..")).Path
$projectRoot = Join-Path $repositoryRoot "src"
$fixtureRoot = Join-Path $projectRoot "scripts\scenario_runtime\tests\fixtures\sandbox-abuse"
$hostExecutable = Join-Path $hostRoot "target\debug\scenario-sandbox-host.exe"

if ([string]::IsNullOrWhiteSpace($GodotExecutable)) {
    $godotCommand = Get-Command godot -ErrorAction SilentlyContinue
    if ($null -eq $godotCommand) {
        throw "Pass -GodotExecutable with a Godot 4 console executable."
    }
    $GodotExecutable = $godotCommand.Source
}
$GodotExecutable = (Resolve-Path -LiteralPath $GodotExecutable).Path

cargo build --manifest-path (Join-Path $hostRoot "Cargo.toml")
if ($LASTEXITCODE -ne 0) {
    throw "The scenario sandbox host did not build."
}

$packageHash = "b" * 64
$nonce = "a" * 64
$tempBase = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempBase ("realmz-sandbox-acceptance-" + [guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null

function Get-Sha256([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function Start-Sandbox([string]$PackageRoot) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $hostExecutable
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @(
        "--protocol", "1",
        "--godot-executable", $GodotExecutable,
        "--project-root", $projectRoot,
        "--package-root", $PackageRoot,
        "--package-hash", $packageHash,
        "--nonce", $nonce
    )) {
        $start.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw "Could not start the scenario sandbox host."
    }
    return $process
}

function Read-Response(
    [System.Diagnostics.Process]$Process,
    [int]$TimeoutMilliseconds = 12000
) {
    $read = $Process.StandardOutput.ReadLineAsync()
    if (-not $read.Wait($TimeoutMilliseconds)) {
        throw "Timed out waiting for the scenario sandbox host."
    }
    $line = $read.Result
    if ([string]::IsNullOrWhiteSpace($line)) {
        $errorText = $Process.StandardError.ReadToEnd()
        throw "Scenario sandbox host exited without JSON: $errorText"
    }
    return $line | ConvertFrom-Json
}

function Invoke-Fixture(
    [string]$FixtureName,
    [string[]]$Capabilities = @("core.presentation.text")
) {
    $caseRoot = Join-Path $tempRoot ([guid]::NewGuid().ToString("N"))
    $sourceRoot = Join-Path $caseRoot "remake\source"
    [System.IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    $sourcePath = Join-Path $fixtureRoot $FixtureName
    $targetPath = Join-Path $sourceRoot $FixtureName
    [System.IO.File]::Copy($sourcePath, $targetPath)

    $process = Start-Sandbox $caseRoot
    try {
        $handshake = @{
            type = "handshake"
            protocolVersion = 1
            nonce = $nonce
        } | ConvertTo-Json -Compress
        $process.StandardInput.WriteLine($handshake)
        $process.StandardInput.Flush()
        $handshakeResponse = Read-Response $process
        if ($handshakeResponse.status -ne "ok") {
            throw "Sandbox handshake failed for $FixtureName."
        }

        $request = @{
            type = "step"
            script = @{
                id = "scenario.security." + $FixtureName.Replace(".gd", "")
                sourcePath = "remake/source/$FixtureName"
                contentHash = Get-Sha256 $targetPath
                apiVersion = 2
                capabilities = $Capabilities
                stateSchemaHash = "c" * 64
            }
            event = @{ kind = "invoke" }
            state = @{}
        } | ConvertTo-Json -Depth 8 -Compress
        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()
        return Read-Response $process
    }
    finally {
        if (-not $process.HasExited) {
            $process.StandardInput.WriteLine('{"type":"stop"}')
            $process.StandardInput.Flush()
            if (-not $process.WaitForExit(2000)) {
                $process.Kill($true)
            }
        }
        $process.Dispose()
    }
}

try {
    foreach ($fixture in @(
        "denied-filesystem.gd",
        "denied-network.gd",
        "denied-process.gd",
        "denied-reflection.gd",
        "denied-resource.gd"
    )) {
        $response = Invoke-Fixture $fixture
        if ($response.status -ne "error" -or $response.message -notmatch "denied") {
            throw "$fixture was not rejected by the sandbox API guard."
        }
    }

    $oversized = Invoke-Fixture "oversized-state.gd"
    if ($oversized.status -ne "error" -or $oversized.message -notmatch "state") {
        throw "Oversized sandbox state was not rejected."
    }

    $undeclared = Invoke-Fixture "undeclared-command.gd"
    if (
        $undeclared.status -ne "ok" -or
        $undeclared.result.kind -ne "error" -or
        $undeclared.result.message -notmatch "Undeclared"
    ) {
        throw "An undeclared sandbox command escaped capability validation."
    }

    $runaway = Invoke-Fixture "runaway.gd"
    if ($runaway.status -ne "error" -or $runaway.message -notmatch "wall-time") {
        throw "Runaway sandbox execution did not hit the wall-time limit."
    }

    $payloadRoot = Join-Path $tempRoot "native-payload"
    $payloadSource = Join-Path $payloadRoot "remake\source"
    [System.IO.Directory]::CreateDirectory($payloadSource) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $payloadSource "forbidden.dll"),
        "not a library"
    )
    $payloadProcess = Start-Sandbox $payloadRoot
    $payloadResponse = Read-Response $payloadProcess 5000
    if ($payloadResponse.status -ne "error" -or $payloadResponse.message -notmatch "non-GDScript") {
        throw "A native payload was not rejected before sandbox startup."
    }
    $payloadProcess.WaitForExit(2000) | Out-Null
    $payloadProcess.Dispose()

    Write-Output "Scenario sandbox security acceptance passed."
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    if (-not $resolvedTemp.StartsWith(
        [System.IO.Path]::GetFullPath($tempBase),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove a sandbox test folder outside the system temp directory."
    }
    if ([System.IO.Directory]::Exists($resolvedTemp)) {
        [System.IO.Directory]::Delete($resolvedTemp, $true)
    }
}
