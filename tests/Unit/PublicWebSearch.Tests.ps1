#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:SearchRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $script:SearchRepoRoot 'src\AiCliProfileManager\Support\PublicWebSearch.ps1')
}

Describe 'Managed public web search' {
    It 'publishes one bounded function tool with no caller-controlled endpoint' {
        $spec = Get-BridgePublicWebSearchToolSpec
        $spec.type | Should -BeExactly 'function'
        $spec.name | Should -BeExactly 'public_web_search'
        $spec.inputSchema.additionalProperties | Should -BeFalse
        @($spec.inputSchema.required) | Should -Be @('query')
        @($spec.inputSchema.properties.PSObject.Properties.Name | Sort-Object) |
            Should -Be @('count','query')
        ($spec | ConvertTo-Json -Depth 20 -Compress) |
            Should -Not -Match 'endpoint|url|uri|header|token|key'
    }

    It 'parses bounded RSS results as untrusted public metadata without active content' {
        $rss = @'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel>
  <item><title>Result &amp; One</title><link>https://example.com/one</link><description>&lt;b&gt;First&lt;/b&gt; result</description></item>
  <item><title>Two</title><link>javascript:alert(1)</link><description>unsafe URL</description></item>
  <item><title>Three</title><link>https://example.org/three</link><description>Third result</description></item>
</channel></rss>
'@
        $results = ConvertFrom-BridgeBingRss `
            -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($rss)) `
            -MaxResults 2

        @($results).Count | Should -Be 2
        $results[0].title | Should -BeExactly 'Result & One'
        $results[0].url | Should -BeExactly 'https://example.com/one'
        $results[0].snippet | Should -BeExactly 'First result'
        $results[1].url | Should -BeExactly 'https://example.org/three'
        ($results | ConvertTo-Json -Depth 10 -Compress) |
            Should -Not -Match '<b>|javascript:'
    }

    It 'rejects DTD and oversized or malformed search arguments' {
        $dtd = '<!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///c:/windows/win.ini">]><rss><channel><item><title>&xxe;</title><link>https://example.com</link></item></channel></rss>'
        {
            ConvertFrom-BridgeBingRss `
                -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($dtd)) `
                -MaxResults 1
        } | Should -Throw '*RSS*'

        foreach ($arguments in @(
            [ordered]@{},
            [ordered]@{ query = ('x' * 257) },
            [ordered]@{ query = "line`nbreak" },
            [ordered]@{ query = 'ok'; count = 0 },
            [ordered]@{ query = 'ok'; count = 6 },
            [ordered]@{ query = 'ok'; endpoint = 'http://127.0.0.1/' }
        )) {
            { ConvertTo-BridgePublicWebSearchArguments -Arguments $arguments } |
                Should -Throw -Because ($arguments | ConvertTo-Json -Compress)
        }
    }

    It 'accepts only the fixed HTTPS Bing RSS endpoint and exact query' {
        $query = 'Codex public search'
        $valid = [uri]('https://cn.bing.com/search?format=rss&count=5&q=' +
            [uri]::EscapeDataString($query))
        Test-BridgeBingEndpointUri -Uri $valid -Query $query | Should -BeTrue

        foreach ($uri in @(
            'https://www.bing.com/search?format=rss&q=Codex%20public%20search',
            'http://cn.bing.com/search?format=rss&q=Codex%20public%20search',
            'https://bing.com.evil.example/search?format=rss&q=Codex%20public%20search',
            'https://127.0.0.1/search?format=rss&q=Codex%20public%20search',
            'https://cn.bing.com/other?format=rss&q=Codex%20public%20search',
            'https://cn.bing.com/search?format=rss&q=different'
        )) {
            Test-BridgeBingEndpointUri -Uri ([uri]$uri) -Query $query |
                Should -BeFalse -Because $uri
        }
    }

    It 'returns only the stable provider envelope and never echoes secret-like arguments' {
        Mock Invoke-BridgeBingRssRequest {
            [Text.UTF8Encoding]::new($false).GetBytes(@'
<rss version="2.0"><channel><item><title>Safe title</title><link>https://example.com/safe</link><description>Safe snippet</description></item></channel></rss>
'@)
        }
        $response = Invoke-BridgePublicWebSearch -Arguments ([ordered]@{
            query = 'current Codex release'
            count = 1
        })
        $response.success | Should -BeTrue
        @($response.contentItems).Count | Should -Be 1
        $payload = $response.contentItems[0].text | ConvertFrom-Json
        $payload.schemaVersion | Should -Be 1
        $payload.provider | Should -BeExactly 'bing-rss-v1'
        $payload.resultCount | Should -Be 1
        $payload.results[0].url | Should -BeExactly 'https://example.com/safe'
        ($response | ConvertTo-Json -Depth 20 -Compress) |
            Should -Not -Match 'current Codex release|authorization|api.?key'
    }
}
