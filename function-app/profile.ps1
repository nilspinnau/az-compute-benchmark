using namespace System.Net

# Authenticate to Azure using the Function App's managed identity.
if ($env:IDENTITY_ENDPOINT) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -AccountId $env:AZURE_CLIENT_ID | Out-Null
}
