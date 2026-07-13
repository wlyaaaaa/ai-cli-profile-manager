# Isolated stdio nonce tool for Live Tool Test.
# Accepts only a fixed protocol; no path/command parameters.
param(
    [Parameter(Mandatory)][string]$Nonce
)

$ErrorActionPreference = 'Stop'
# Simple line protocol: client sends "PING", server replies "NONCE <value>"
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line -eq 'QUIT') { break }
    if ($line -eq 'PING' -or $line -eq 'GET_NONCE') {
        [Console]::Out.WriteLine("NONCE $Nonce")
        [Console]::Out.Flush()
        continue
    }
    [Console]::Out.WriteLine('ERR unsupported')
    [Console]::Out.Flush()
}
