param(
    [string]$RemoteName = 'production',
    [Parameter(Mandatory = $true)]
    [string]$Server,
    [string]$IdentityFile = ''
)

$ErrorActionPreference = 'Stop'

git rev-parse --is-inside-work-tree | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Run this script inside the blog Git repository.' }

$remote = git remote get-url $RemoteName 2>$null
if ($LASTEXITCODE -ne 0 -or -not $remote) {
    throw "Git remote '$RemoteName' is not configured."
}

$revision = (git rev-parse HEAD).Trim()
pnpm build
if ($LASTEXITCODE -ne 0) { throw 'Local blog build failed.' }

if ($IdentityFile) {
    $resolvedIdentity = (Resolve-Path -LiteralPath $IdentityFile).Path
    $sshCommand = "ssh -o IdentitiesOnly=yes -i `"$resolvedIdentity`""
    git -c "core.sshCommand=$sshCommand" push $RemoteName HEAD:main
} else {
    git push $RemoteName HEAD:main
}

if ($LASTEXITCODE -ne 0) { throw 'Production deployment failed.' }

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$deployTemp = Join-Path $tempRoot ("twilight-deploy-" + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $deployTemp 'site.tar.gz'
$remoteArchive = "/srv/blog/incoming/site-$revision.tar.gz"

try {
    New-Item -ItemType Directory -Path $deployTemp | Out-Null
    tar -czf $archive -C dist .
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the static-site archive.' }

    $sshOptions = @('-o', 'BatchMode=yes')
    if ($IdentityFile) {
        $sshOptions += @('-o', 'IdentitiesOnly=yes', '-i', $resolvedIdentity)
    }

    & scp @sshOptions $archive "${Server}:$remoteArchive"
    if ($LASTEXITCODE -ne 0) { throw 'Could not upload the static-site archive.' }

    & ssh @sshOptions $Server "/usr/local/sbin/deploy-blog-static '$remoteArchive' '$revision'"
    if ($LASTEXITCODE -ne 0) { throw 'Server-side static deployment failed.' }

    $deployedRevision = (& ssh @sshOptions $Server 'cat /srv/blog/deployed-revision').Trim()
    if ($LASTEXITCODE -ne 0 -or $deployedRevision -ne $revision) {
        throw "Server deployed revision '$deployedRevision', expected '$revision'."
    }
} finally {
    $fullDeployTemp = [IO.Path]::GetFullPath($deployTemp)
    if ($fullDeployTemp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $fullDeployTemp)) {
        [IO.Directory]::Delete($fullDeployTemp, $true)
    }
}

Write-Host "Production deployed: $revision"
