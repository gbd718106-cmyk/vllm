<#
.SYNOPSIS
    Build the RunPod vLLM worker image and push it to Docker Hub.

.DESCRIPTION
    Wraps the two commands from the README (docker build / docker push) in one
    script, with the platform pinned to linux/amd64 (RunPod GPUs are x86_64) and
    the vLLM base tag taken from a parameter.

    Run `docker login` once yourself first (interactive password / access token),
    or pass -Login to be prompted by the Docker CLI.

.EXAMPLE
    .\scripts\build_and_push.ps1 -DockerHubUser yourname

.EXAMPLE
    .\scripts\build_and_push.ps1 -DockerHubUser yourname -Tag v0.32.0 -Login

.EXAMPLE
    # Bake a model into the image (needs HF_TOKEN for gated repos).
    .\scripts\build_and_push.ps1 -DockerHubUser yourname -ModelName Qwen/Qwen3-8B
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DockerHubUser,

    [string] $ImageName = 'worker-v1-vllm',
    [string] $Tag = 'latest',
    [string] $VllmVersion = 'v0.32.0',
    [string] $Platform = 'linux/amd64',

    # Optional: bake the model into the image at build time.
    [string] $ModelName = '',
    [string] $ModelRevision = '',
    [string] $TokenizerName = '',
    [string] $Quantization = '',

    # HF_TOKEN (build secret) for gated model repos.
    [string] $HfToken = '',

    [switch] $Login,
    [switch] $NoPush
)

$ErrorActionPreference = 'Stop'

function Assert-Docker {
    $cmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "docker CLI not found on PATH. Install/start Docker Desktop, open a NEW terminal, then re-run."
    }
    docker version --format '{{.Server.Version}}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker engine is not reachable. Is Docker Desktop running (green whale)?"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$image = "$DockerHubUser/$ImageName`:$Tag"

Write-Host "==> repo:    $repoRoot"
Write-Host "==> image:   $image"
Write-Host "==> vLLM:    $VllmVersion"
Write-Host "==> platform $Platform"

Assert-Docker

if ($Login) {
    docker login
    if ($LASTEXITCODE -ne 0) { throw "docker login failed." }
}

$buildArgs = @(
    'buildx', 'build',
    '--platform', $Platform,
    '--build-arg', "VLLM_VERSION=$VllmVersion",
    '-t', $image
)

if ($ModelName) {
    $buildArgs += @('--build-arg', "MODEL_NAME=$ModelName")
    if ($ModelRevision) { $buildArgs += @('--build-arg', "MODEL_REVISION=$ModelRevision") }
    if ($TokenizerName) { $buildArgs += @('--build-arg', "TOKENIZER_NAME=$TokenizerName") }
    if ($Quantization) { $buildArgs += @('--build-arg', "QUANTIZATION=$Quantization") }
}

if ($HfToken) {
    # Pass the token as a build secret so it never lands in a layer.
    $secretFile = Join-Path ([System.IO.Path]::GetTempPath()) "hf_token_$PID"
    Set-Content -Path $secretFile -Value $HfToken -NoNewline -Encoding ascii
    $buildArgs += @('--secret', "id=HF_TOKEN,src=$secretFile")
}

if ($NoPush) {
    $buildArgs += '--load'
}

$buildArgs += $repoRoot

try {
    Write-Host "==> docker $($buildArgs -join ' ')"
    & docker @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "docker build failed (exit $LASTEXITCODE)." }
}
finally {
    if ($HfToken -and (Test-Path $secretFile)) { Remove-Item $secretFile -Force }
}

if (-not $NoPush) {
    Write-Host "==> pushing $image"
    docker push $image
    if ($LASTEXITCODE -ne 0) { throw "docker push failed (exit $LASTEXITCODE)." }
    Write-Host "Done: https://hub.docker.com/r/$DockerHubUser/$ImageName"
}
