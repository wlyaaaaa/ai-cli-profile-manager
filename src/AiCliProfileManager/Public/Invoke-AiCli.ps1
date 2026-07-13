function Invoke-AiCli {
    <#
    .SYNOPSIS
      AI CLI Profile Manager entry point (command: aicli).
    .PARAMETER Tokens
      Subcommand and arguments, e.g. profile list
    .PARAMETER DataRoot
      Test-only data root override (not for production docs).
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Tokens,

        [string]$DataRoot
    )

    # Encoding: prefer UTF-8 output without assuming external CLI encoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $script:OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    } catch {}

    if ($DataRoot) {
        Set-AiCliDataRootOverride -Path $DataRoot
    }

    try {
        # List[string] path inside router avoids PS single-element array → string collapse
        # Router must return only an [int] exit code; user text/JSON go to console streams.
        $code = Invoke-AiCliRouter -Tokens $Tokens
        if ($code -is [Array]) {
            $code = @($code | Where-Object { $_ -is [int] } | Select-Object -Last 1)
            if ($code.Count -eq 0) { $code = 5 } else { $code = [int]$code[0] }
        }
        return [int]$code
    } catch {
        Write-Host (Protect-AiCliSecretText $_.Exception.Message) -ForegroundColor Red
        return (Get-AiCliExitCode InternalError)
    } finally {
        if ($DataRoot) {
            Set-AiCliDataRootOverride -Path $null
        }
    }
}

function aicli {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Tokens
    )
    $code = Invoke-AiCli -Tokens $Tokens
    # When used as function, set LASTEXITCODE if possible
    try { $global:LASTEXITCODE = $code } catch {}
    # Interactive command surface should not print a trailing numeric status.
    # Scripts that need the numeric result can call Invoke-AiCli directly.
}
