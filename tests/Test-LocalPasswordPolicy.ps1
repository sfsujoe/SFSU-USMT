# Pure synthetic password validation. No account API, USMT, AD or policy changes.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
if (-not ('Sfsu.Engine.LocalPasswords' -as [type])) { Add-Type -Path (Join-Path $repository 'App/Scripts/Sfsu.Engine.Native.cs') }
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Check([string]$Candidate,[string]$Expected='',[string]$Account='CampusUser',[string]$Name='Morgan Rivera') {
    $secret=[Net.NetworkCredential]::new('',$Candidate).SecurePassword
    try {
        $problem=[Sfsu.Engine.LocalPasswords]::Validate($secret,$Account,$Name)
        if ($Expected) { Assert-True ($problem -match $Expected) 'A rejected password has the expected safe reason.' }
        else { Assert-True (-not $problem) 'An in-scope password passes the local check.' }
        Assert-True (-not $problem -or -not $problem.Contains($Candidate)) 'Validation does not echo a candidate into its result.'
    } finally { $secret.Dispose() }
}
Check 'Abcdefghi!1' '12 characters' # Eleven characters.
Check 'Abcdefghij!1' # Twelve characters.
Check ('A'*12) '3 character categories'
Check ('Aa'*6) '3 character categories'
Check ('9!'*6) '3 character categories'
$groups=@('A','a','1','!',([string][char]0x4e2d))
for ($a=0;$a -lt 5;$a++) { for ($b=$a+1;$b -lt 5;$b++) { for ($c=$b+1;$c -lt 5;$c++) {
    Check (($groups[$a]+$groups[$b]+$groups[$c])*4)
} } }
# Accented case stays in its case category, without counting as a fifth category.
Check (([string][char]0x00c9+'a')*6) '3 character categories'
Check (([string][char]0x00c9+'a1')*4)
# Windows-style special category excludes whitespace and currency symbols.
Check ('Aa '*4) '3 character categories'
Check (('Aa'+[char]0x20ac)*4) '3 character categories'
Check ('Aa\'*4)
Check ('Aa'+[char]0x0000+('x'*10)) 'control characters'
Check ('Aa'+[char]0xd800+('x'*10)) 'invalid Unicode'
# Supplementary letters count as one character and can supply the uncased category.
$supplementary=[char]::ConvertFromUtf32(0x20000)
Check ('Aa'+($supplementary*9)) '12 characters'
Check ('Aa'+($supplementary*10))
Check ('Aa1'+('x'*253))
Check ('Aa1'+('x'*254)) '12-256'
Check 'Welcome-CAMPUSUSER!19' 'account name'
Check 'Welcome-RIVERA!19' 'display-name part'
Check 'Welcome-mOrGaN!19' 'display-name part'
Check 'Welcome-Li!12345' 'display-name part' 'CampusUser' 'Li Chen'
Check 'Welcome-Smith!19' 'display-name part' 'CampusUser' 'Smith, Morgan'
Check 'Welcome-a.b!1234' 'account name' 'a.b'
Check 'Welcome-axb!1234' '' 'a.b'
Check 'Welcome-Password!19' '' 'CampusUser' ''
Assert-True ([Sfsu.Engine.LocalPasswords]::Validate($null,'CampusUser','Morgan Rivera') -match '12-256') 'Missing secrets fail safely.'
Write-Output ("PASS: $script:Assertions local-password assertions on PowerShell "+$PSVersionTable.PSVersion)
