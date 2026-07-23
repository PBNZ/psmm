# Gallery SEARCH (gh#17): the full-text endpoint, the name-pattern path, and
# the rules that decide which one a query gets.
#
# Every test here is offline - Invoke-RestMethod and the provider are mocked.
# The behaviour being pinned is not "the gallery has module X" (that changes
# daily) but "psmm asks the right question and never fails silently".
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    # One <entry> of the ATOM feed the OData Search() endpoint really returns,
    # including the two shapes that are NOT plain strings: a typed field
    # (m:type, value in #text) and a null field (m:null="true").
    function New-GalleryEntryXml {
        param(
            [string]$Id,
            [string]$Version = '1.0.0',
            [string]$Authors = 'someone',
            [string]$Description = 'a module',
            [string]$Summary = '',
            [string]$Downloads = '100',
            [switch]$NullDescription
        )
        $desc = if ($NullDescription) { '<d:Description m:null="true" />' } else { "<d:Description>$Description</d:Description>" }
        @"
  <entry>
    <title type="text">$Id</title>
    <m:properties>
      <d:Id>$Id</d:Id>
      <d:Version>$Version</d:Version>
      <d:Authors>$Authors</d:Authors>
      $desc
      <d:Summary>$Summary</d:Summary>
      <d:DownloadCount m:type="Edm.Int32">$Downloads</d:DownloadCount>
      <d:ProjectUrl>https://example.invalid/$Id</d:ProjectUrl>
      <d:IconUrl m:null="true" />
    </m:properties>
  </entry>
"@
    }

    # Invoke-RestMethod hands back the <entry> elements, not the document.
    function New-GalleryFeed {
        param([string[]]$EntriesXml)
        $doc = [xml](@"
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices"
      xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata">
$($EntriesXml -join "`n")
</feed>
"@)
        @($doc.feed.entry)
    }

    $script:FeedOne = New-GalleryFeed -EntriesXml @(
        New-GalleryEntryXml -Id 'ImportExcel' -Version '7.8.10' -Authors 'Douglas Finke' `
            -Description 'PowerShell module to import/export Excel spreadsheets, without Excel' -Downloads '22940663'
    )
}

Describe 'Gallery search URI' -Tag Engine, Gallery {

    It 'asks the endpoint the website asks, with a server-side limit' {
        InModuleScope psmm {
            $u = Get-PSMMGallerySearchUri -Term 'excel' -First 40
            $u | Should -BeLike 'https://www.powershellgallery.com/api/v2/Search()*'
            $u | Should -Match "searchTerm='excel'"
            $u | Should -Match '\$filter=IsLatestVersion'
            $u | Should -Match '\$top=40'
            $u | Should -Match 'semVerLevel=2\.0\.0'
            $u | Should -Match 'includePrerelease=false'
        }
    }

    # measured 2026-07-23: DownloadCount desc, DownloadCount asc and no
    # $orderby all return the SAME order, so $orderby buys nothing - and an
    # unrecognised field is a hard 400, so sending one is a net risk
    It 'sends no $orderby - the endpoint ignores it and rejects a bad one' {
        InModuleScope psmm {
            (Get-PSMMGallerySearchUri -Term 'excel') | Should -Not -Match '\$orderby'
        }
    }

    It 'doubles single quotes before encoding, so a quoted term cannot break the literal' {
        InModuleScope psmm {
            # OData escapes ' as '', which percent-encodes to %27%27
            (Get-PSMMGallerySearchUri -Term "it's") | Should -Match 'searchTerm=%27it%27%27s%27|searchTerm=.it%27%27s.'
        }
    }

    It 'encodes a term that would otherwise end the query string' {
        InModuleScope psmm {
            $u = Get-PSMMGallerySearchUri -Term 'a&b#c'
            $u | Should -Match '%26'
            $u | Should -Match '%23'
            # the filter must survive intact after the term
            $u | Should -Match '\$filter=IsLatestVersion'
        }
    }

    It 'clamps $top into the range the endpoint accepts' {
        InModuleScope psmm {
            (Get-PSMMGallerySearchUri -Term 'x' -First 5000) | Should -Match '\$top=200'
            (Get-PSMMGallerySearchUri -Term 'x' -First 0) | Should -Match '\$top=1'
        }
    }

    It 'switches to prereleases only when asked' {
        InModuleScope psmm {
            (Get-PSMMGallerySearchUri -Term 'psmm' -Prerelease) | Should -Match 'includePrerelease=true'
        }
    }
}

Describe 'OData property reading' -Tag Engine, Gallery {

    It 'reads a plain string, a typed value and a null field' {
        # one entry, not the feed: an XmlElement indexes by CHILD NAME, so
        # $feed[0] on a single-element result would quietly yield $null
        InModuleScope psmm -Parameters @{ entry = @($script:FeedOne)[0] } {
            param($entry)
            $p = $entry.properties
            Get-PSMMODataText $p.Id | Should -Be 'ImportExcel'
            # <d:DownloadCount m:type="Edm.Int32">: the value lives in #text,
            # and reading the node itself yields "System.Xml.XmlElement"
            Get-PSMMODataText $p.DownloadCount | Should -Be '22940663'
            # <d:IconUrl m:null="true" />
            Get-PSMMODataText $p.IconUrl | Should -Be ''
            Get-PSMMODataText $null | Should -Be ''
        }
    }

    It 'converts an entry into a result, splitting the prerelease label out' {
        InModuleScope psmm -Parameters @{ entry = @($script:FeedOne)[0] } {
            param($entry)
            $r = ConvertFrom-PSMMGalleryEntry -Entry $entry
            $r.Name | Should -Be 'ImportExcel'
            $r.Version | Should -Be '7.8.10'
            $r.Prerelease | Should -Be ''
            $r.Author | Should -Be 'Douglas Finke'
            $r.Downloads | Should -Be 22940663
            $r.Repository | Should -Be 'PSGallery'
            $r.Description | Should -Match 'Excel'
        }
    }

    It 'keeps the prerelease label off the base version' {
        InModuleScope psmm {
            $doc = [xml]'<feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata"><entry><m:properties><d:Id>psmm</d:Id><d:Version>0.1.0-beta9</d:Version><d:Description>x</d:Description></m:properties></entry></feed>'
            $r = ConvertFrom-PSMMGalleryEntry -Entry @($doc.feed.entry)[0]
            $r.Version | Should -Be '0.1.0'
            $r.Prerelease | Should -Be 'beta9'
        }
    }

    It 'falls back to Summary when Description is null' {
        InModuleScope psmm {
            $doc = [xml]'<feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata"><entry><m:properties><d:Id>M</d:Id><d:Version>1.0</d:Version><d:Description m:null="true" /><d:Summary>the short one</d:Summary></m:properties></entry></feed>'
            (ConvertFrom-PSMMGalleryEntry -Entry @($doc.feed.entry)[0]).Description | Should -Be 'the short one'
        }
    }

    It 'treats a no-hit response ($null) as zero results, not one empty one' {
        InModuleScope psmm {
            Mock Invoke-RestMethod { $null }
            @(Find-PSMMGalleryFullText -Term 'zzzz').Count | Should -Be 0
        }
    }

    It 'bounds the request in time - a hung endpoint must not hang the UI' {
        InModuleScope psmm {
            Mock Invoke-RestMethod { $null }
            $null = Find-PSMMGalleryFullText -Term 'x'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $TimeoutSec -gt 0 }
        }
    }
}

Describe 'Which search a query gets' -Tag Engine, Gallery {

    # end to end over the real seam: query in, HTTP call out, results back
    It 'sends a bare word to full text and NEVER builds a leading wildcard' {
        InModuleScope psmm -Parameters @{ feed = $script:FeedOne } {
            param($feed)
            @($feed).Count | Should -Be 1                  # the fixture is what we think it is
            Mock Invoke-RestMethod { $feed }
            Mock Find-PSMMGalleryByName { @() }
            Mock Get-PSMMExtraRepository { @() }
            $s = Search-PSMMGallery -Query 'excel'
            $s.Mode | Should -Be 'fulltext'
            $s.Results.Count | Should -Be 1
            $s.Results[0].Name | Should -Be 'ImportExcel'
            $s.Note | Should -Be ''
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match "searchTerm='excel'" }
            # the whole bug: "*excel*" is what PSResourceGet has been seen to
            # answer with 0 results and 0 errors
            Should -Not -Invoke Find-PSMMGalleryByName
        }
    }

    It 'sends an explicit wildcard to the provider, untouched' {
        InModuleScope psmm {
            Mock Invoke-RestMethod { throw 'the endpoint must not be used for a name pattern' }
            Mock Get-PSMMExtraRepository { @() }
            Mock Find-PSMMGalleryByName { @([pscustomobject]@{ Name = 'Az.Accounts' }) } -ParameterFilter { $Pattern -eq 'Az.*' }
            $s = Search-PSMMGallery -Query 'Az.*'
            $s.Mode | Should -Be 'name'
            $s.Results[0].Name | Should -Be 'Az.Accounts'
            Should -Invoke Find-PSMMGalleryByName -Times 1 -Exactly
        }
    }

    It 'rescues a pattern that matched nothing by searching its words instead' {
        InModuleScope psmm {
            Mock Find-PSMMGalleryByName { @() }
            Mock Get-PSMMExtraRepository { @() }
            Mock Find-PSMMGalleryFullText { @([pscustomobject]@{ Name = 'ImportExcel' }) }
            $s = Search-PSMMGallery -Query '*excel*'
            $s.Mode | Should -Be 'fulltext-fallback'
            $s.Results[0].Name | Should -Be 'ImportExcel'
            $s.Note | Should -Match "showing gallery matches for 'excel'"
            # the wildcards are stripped for the retry, not passed through
            Should -Invoke Find-PSMMGalleryFullText -Times 1 -Exactly -ParameterFilter { $Term -eq 'excel' }
        }
    }

    It 'falls back to a name PREFIX - never a leading wildcard - when the endpoint fails' {
        InModuleScope psmm {
            Mock Invoke-RestMethod { throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }
            Mock Get-PSMMExtraRepository { @() }
            Mock Find-PSMMGalleryByName { @([pscustomobject]@{ Name = 'ExcelAnt' }) }
            $s = Search-PSMMGallery -Query 'excel'
            $s.Mode | Should -Be 'name-fallback'
            $s.Results[0].Name | Should -Be 'ExcelAnt'
            $s.Note | Should -Match 'did not answer'
            $s.Note | Should -Match 'No such host'
            Should -Invoke Find-PSMMGalleryByName -Times 1 -Exactly -ParameterFilter { $Pattern -eq 'excel*' }
        }
    }

    It 'retries with prereleases when nothing stable matches (psmm is such a module)' {
        InModuleScope psmm {
            $pre = [xml]'<feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata"><entry><m:properties><d:Id>psmm</d:Id><d:Version>0.1.0-beta9</d:Version><d:Description>x</d:Description></m:properties></entry></feed>'
            Mock Get-PSMMExtraRepository { @() }
            Mock Invoke-RestMethod { $null } -ParameterFilter { $Uri -match 'includePrerelease=false' }
            Mock Invoke-RestMethod { @($pre.feed.entry) } -ParameterFilter { $Uri -match 'includePrerelease=true' }
            $s = Search-PSMMGallery -Query 'psmm'
            $s.Results.Count | Should -Be 1
            $s.Results[0].Prerelease | Should -Be 'beta9'
            $s.Note | Should -Match 'Only prerelease versions'
        }
    }

    It 'never comes back empty AND silent - there is always a reason' {
        InModuleScope psmm {
            Mock Invoke-RestMethod { $null }
            Mock Get-PSMMExtraRepository { @() }
            Mock Find-PSMMGalleryByName { @() }
            (Search-PSMMGallery -Query 'zzzznotamodule').Note | Should -Not -BeNullOrEmpty
            (Search-PSMMGallery -Query '*zzzznotamodule*').Note | Should -Not -BeNullOrEmpty
            (Search-PSMMGallery -Query '   ').Note | Should -Not -BeNullOrEmpty
            (Search-PSMMGallery -Query '*').Note | Should -Not -BeNullOrEmpty
        }
    }

    It 'survives a query made only of wildcards' {
        InModuleScope psmm {
            Mock Invoke-RestMethod { throw 'must not be called: there is no term left to search' }
            Mock Get-PSMMExtraRepository { @() }
            Mock Find-PSMMGalleryByName { @() }
            { Search-PSMMGallery -Query '*?*' } | Should -Not -Throw
            (Search-PSMMGallery -Query '*?*').Results.Count | Should -Be 0
        }
    }
}

Describe 'Repositories other than the public gallery' -Tag Engine, Gallery {

    It 'asks them through the provider, because the endpoint cannot see them' {
        InModuleScope psmm {
            Mock Find-PSMMGalleryFullText { @([pscustomobject]@{ Name = 'ImportExcel'; Repository = 'PSGallery' }) }
            Mock Get-PSMMExtraRepository { @('Internal') }
            Mock Find-PSMMGalleryByName { @([pscustomobject]@{ Name = 'Contoso.Tools'; Repository = 'Internal' }) }
            $s = Search-PSMMGallery -Query 'excel'
            Should -Invoke Find-PSMMGalleryByName -Times 1 -Exactly -ParameterFilter { $Repository -contains 'Internal' }
            @($s.Results).Name | Should -Contain 'Contoso.Tools'
            @($s.Results).Name | Should -Contain 'ImportExcel'
        }
    }

    It 'bounds them so a big internal feed cannot bury the gallery ranking' {
        InModuleScope psmm {
            Mock Find-PSMMGalleryFullText { @([pscustomobject]@{ Name = 'ImportExcel' }) }
            Mock Get-PSMMExtraRepository { @('Internal') }
            Mock Find-PSMMGalleryByName { @() }
            $null = Search-PSMMGallery -Query 'excel' -First 40
            Should -Invoke Find-PSMMGalleryByName -Times 1 -Exactly -ParameterFilter { $First -le 10 }
        }
    }

    It 'costs nothing when only the public gallery is registered' {
        InModuleScope psmm {
            Mock Find-PSMMGalleryFullText { @([pscustomobject]@{ Name = 'ImportExcel' }) }
            Mock Get-PSMMExtraRepository { @() }
            Mock Find-PSMMGalleryByName { @() }
            $null = Search-PSMMGallery -Query 'excel'
            Should -Not -Invoke Find-PSMMGalleryByName
        }
    }

    It 'reads the extra repositories from the provider, ignoring the gallery itself' {
        InModuleScope psmm {
            Mock Get-PSResourceRepository {
                @(
                    [pscustomobject]@{ Name = 'PSGallery'; Uri = 'https://www.powershellgallery.com/api/v2' }
                    [pscustomobject]@{ Name = 'Internal'; Uri = 'https://nuget.example.invalid/v3/index.json' }
                )
            }
            $names = @(Get-PSMMExtraRepository)
            $names | Should -Be @('Internal')
        }
    }

    It 'reports nothing rather than throwing when the provider refuses to enumerate' {
        InModuleScope psmm {
            Mock Get-PSResourceRepository { throw 'nope' }
            @(Get-PSMMExtraRepository).Count | Should -Be 0
        }
    }
}

Describe 'Merging and formatting' -Tag Engine, Gallery {

    It 'keeps the first of a duplicated name and honours the limit' {
        InModuleScope psmm {
            $a = @([pscustomobject]@{ Name = 'Dup'; Repository = 'Internal' }, [pscustomobject]@{ Name = 'A' })
            $b = @([pscustomobject]@{ Name = 'dup'; Repository = 'PSGallery' }, [pscustomobject]@{ Name = 'B' })
            $m = Merge-PSMMGalleryResult -Primary $a -Secondary $b
            @($m).Count | Should -Be 3
            $m[0].Repository | Should -Be 'Internal'
            @(Merge-PSMMGalleryResult -Primary $a -Secondary $b -Limit 2).Count | Should -Be 2
        }
    }

    It 'tolerates empty and null sides' {
        InModuleScope psmm {
            @(Merge-PSMMGalleryResult -Primary $null -Secondary @()).Count | Should -Be 0
            @(Merge-PSMMGalleryResult -Primary @([pscustomobject]@{ Name = 'A' }) -Secondary $null).Count | Should -Be 1
        }
    }

    It 'shortens a download count and shows nothing when it is unknown' {
        InModuleScope psmm {
            Format-PSMMDownloadCount 2147483647 | Should -Be '2.1B'
            Format-PSMMDownloadCount 22940663 | Should -Be '22.9M'
            Format-PSMMDownloadCount 432624 | Should -Be '432.6k'
            Format-PSMMDownloadCount 8007 | Should -Be '8k'
            Format-PSMMDownloadCount 42 | Should -Be '42'
            Format-PSMMDownloadCount 0 | Should -Be ''
            Format-PSMMDownloadCount $null | Should -Be ''
            Format-PSMMDownloadCount 'not a number' | Should -Be ''
        }
    }
}

Describe 'The provider adapter' -Tag Engine, Gallery {

    It 'passes the pattern and repository straight through and normalises the result' {
        InModuleScope psmm {
            Mock Find-PSResource {
                @([pscustomobject]@{
                        Name = 'Contoso.Tools'; Version = '2.1.0'; Prerelease = '-rc1'
                        Description = 'internal'; Author = 'Contoso'; ProjectUri = 'https://example.invalid'
                        Repository = 'Internal'
                    })
            }
            $r = @(Find-PSMMGalleryByName -Pattern '*tools*' -Repository @('Internal'))
            Should -Invoke Find-PSResource -Times 1 -Exactly -ParameterFilter {
                $Name -eq '*tools*' -and $Repository -contains 'Internal'
            }
            $r[0].Name | Should -Be 'Contoso.Tools'
            $r[0].Prerelease | Should -Be 'rc1'      # the leading '-' is not part of the label
            $r[0].Repository | Should -Be 'Internal'
            $r[0].Downloads | Should -Be 0           # the provider does not report one
        }
    }
}
