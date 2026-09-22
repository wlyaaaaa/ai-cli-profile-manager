using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace AiCli.GeminiBridge;

// An installation compatibility receipt, not a model answer and not a new
// authorization source. It is invalid whenever the tested runtime or policy changes.
public static class IsolationAttestation
{
    public static void Verify(BridgeSettings settings)
    {
        if(string.IsNullOrWhiteSpace(settings.IsolationReceiptPath))throw new BridgeException("isolation_verification_required",503);
        try
        {
            OwnedStorage.AssertNotReparse(settings.IsolationReceiptPath);
            var receipt=JsonNode.Parse(File.ReadAllText(settings.IsolationReceiptPath,new UTF8Encoding(false,true)))?.AsObject()
                ??throw new BridgeException("isolation_receipt_invalid",503);
            ValidateReceipt(receipt,settings.AgySha256,HashFile(settings.PowerShellExecutable),AntigravitySession.IsolationTemplateFingerprint);
        }
        catch(BridgeException){throw;}
        catch(Exception e) when(e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or DecoderFallbackException)
        {throw new BridgeException("isolation_verification_required",503);}
    }
    public static void ValidateReceipt(JsonObject receipt,string cliHash,string interpreterHash,string templateHash)
    {
        if(JsonValueReader.Text(receipt,"schema")!="aicli.antigravity-isolation.v2" ||
            JsonValueReader.Text(receipt,"cliSha256")!=cliHash.ToLowerInvariant() ||
            JsonValueReader.Text(receipt,"interpreterSha256")!=interpreterHash.ToLowerInvariant() ||
            JsonValueReader.Text(receipt,"templateSha256")!=templateHash ||
            !JsonValueReader.Boolean(receipt,"preToolDenialObserved",false) ||
            !JsonValueReader.Boolean(receipt,"cleanupVerified",false) ||
            !DateTimeOffset.TryParse(JsonValueReader.Text(receipt,"verifiedUtc"),out _))
            throw new BridgeException("isolation_receipt_mismatch",503);
    }
    public static async Task<JsonObject> VerifyAndWriteAsync(BridgeSettings settings,GeminiSelection model,CancellationToken token)
    {
        if(string.IsNullOrWhiteSpace(settings.IsolationReceiptPath)||!Path.IsPathFullyQualified(settings.IsolationReceiptPath))
            throw new BridgeException("isolation_receipt_path_required",503);
        var interpreter=HashFile(settings.PowerShellExecutable);var template=AntigravitySession.IsolationTemplateFingerprint;
        await using(var probe=await AntigravitySession.CreateIsolationProbeAsync(settings,model.ExactModel,model.CliEffort,token).ConfigureAwait(false))
        {
            // CreateIsolationProbeAsync returns only after the actual native
            // call was rejected and the model acknowledged the unique nonce.
        }
        settings.Validate();if(HashFile(settings.PowerShellExecutable)!=interpreter || AntigravitySession.IsolationTemplateFingerprint!=template)
            throw new BridgeException("isolation_runtime_changed_during_probe",503);
        token.ThrowIfCancellationRequested();
        var receipt=new JsonObject{["schema"]="aicli.antigravity-isolation.v2",["cliSha256"]=settings.AgySha256.ToLowerInvariant(),
            ["interpreterSha256"]=interpreter,["templateSha256"]=template,["verifiedUtc"]=DateTimeOffset.UtcNow.ToString("O"),
            ["verificationModel"]=model.ExactModel,["preToolDenialObserved"]=true,["cleanupVerified"]=true};
        var parent=Path.GetDirectoryName(settings.IsolationReceiptPath)!;Directory.CreateDirectory(parent);OwnedStorage.AssertNotReparse(parent);
        var temp=settings.IsolationReceiptPath+".new-"+Guid.NewGuid().ToString("N");
        try{await File.WriteAllTextAsync(temp,receipt.ToJsonString()+"\n",new UTF8Encoding(false),token).ConfigureAwait(false);File.Move(temp,settings.IsolationReceiptPath,true);}
        finally{if(File.Exists(temp))File.Delete(temp);}
        Verify(settings);return receipt;
    }
    private static string HashFile(string path){using var f=File.OpenRead(path);return Convert.ToHexString(SHA256.HashData(f)).ToLowerInvariant();}
}