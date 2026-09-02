param(
    [string]$RemoteName = 'production',
    [string]$IdentityFile = ''
)

$ErrorActionPreference = 'Stop'

git rev-parse --is-inside-work-tree | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Run this script inside the blog Git repository.' }

$remote = git remote get-url $RemoteName 2>$null
if ($LASTEXITCODE -ne 0 -or -not $remote) {
    throw "Git remote '$RemoteName' is not configured."
}

if ($IdentityFile) {
    $resolvedIdentity = (Resolve-Path -LiteralPath $IdentityFile).Path
    $sshCommand = "ssh -o IdentitiesOnly=yes -i `"$resolvedIdentity`""
    git -c "core.sshCommand=$sshCommand" push $RemoteName HEAD:main
} else {
    git push $RemoteName HEAD:main
}

if ($LASTEXITCODE -ne 0) { throw 'Production deployment failed.' }
