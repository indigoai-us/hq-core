[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$EncodedArguments
)

# Base64 keeps caller-controlled values out of PowerShell's parameter syntax.
# The call operator then keeps the decoded command and its arguments separate,
# so Node never constructs a `cmd.exe /c` program string from tool input.
$DecodedArguments = @(
    $EncodedArguments | ForEach-Object {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))
    }
)
$CommandPath = $DecodedArguments[0]
$CommandArguments = @($DecodedArguments | Select-Object -Skip 1)
& $CommandPath @CommandArguments
if ($null -eq $LASTEXITCODE) {
    exit 0
}
exit $LASTEXITCODE
