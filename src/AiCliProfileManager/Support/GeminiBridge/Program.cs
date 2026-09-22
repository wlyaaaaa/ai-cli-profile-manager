using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AiCli.GeminiBridge;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if(args.Length==1&&args[0]=="--describe-runtime")
            {
                Console.WriteLine(JsonSerializer.Serialize(new{driverProtocolVersion=2,modelSetSchema="aicli.gemini-model-set.v1",
                    isolationSchema="aicli.antigravity-isolation.v2",isolationTemplateSha256=AntigravitySession.IsolationTemplateFingerprint}));return 0;
            }
            if(args.Length==2&&args[0]=="--validate-models")
            {
                var data=GeminiModelSet.Load(args[1]);
                Console.WriteLine(JsonSerializer.Serialize(new{valid=true,fingerprint=data.Fingerprint,defaultModel=data.DefaultModel,
                    models=data.Models.Select(m=>new{m.Id,m.ProfileId,m.MenuModel,m.DefaultEffort,m.ContextWindow,m.AutoCompactPercent,m.Efforts})}));
                return 0;
            }
            if(args.Length!=2||args[0] is not ("--settings" or "--verify-isolation"))throw new BridgeException("settings_file_required",503);
            if(!OperatingSystem.IsWindows())throw new BridgeException("windows_required",503);
            using var identity=WindowsIdentity.GetCurrent();
            if(identity.IsSystem)throw new BridgeException("consumer_user_session_required",503);
            var settings=JsonSerializer.Deserialize<BridgeSettings>(await File.ReadAllTextAsync(args[1]).ConfigureAwait(false),new JsonSerializerOptions{PropertyNameCaseInsensitive=true})
                ??throw new BridgeException("invalid_bridge_settings",503);
            settings.Validate();
            if(settings.ModelCatalogPath is null)throw new BridgeException("model_set_path_required",503);
            var models=GeminiModelSet.Load(settings.ModelCatalogPath);
            if(models.ApprovedCliSha256!=settings.AgySha256.ToLowerInvariant())throw new BridgeException("model_set_cli_identity_mismatch",503);
            if(args[0]=="--verify-isolation")
            {
                using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(settings.TurnTimeoutSeconds+15));
                var receipt=await IsolationAttestation.VerifyAndWriteAsync(settings,models.Resolve(models.DefaultModel,null),timeout.Token).ConfigureAwait(false);
                Console.WriteLine(receipt.ToJsonString());return 0;
            }
            IsolationAttestation.Verify(settings);
            var token=Environment.GetEnvironmentVariable("AICLI_GEMINI_BRIDGE_TOKEN")??throw new BridgeException("local_bearer_token_required",503);
            using var owner=new FileStream(Path.Combine(settings.RuntimeDirectory,".owner.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
            RecoverOwnedSessions(settings.RuntimeDirectory);
            var validator=new PowerShellSchemaValidator(settings.PowerShellExecutable,settings.RuntimeDirectory);
            await using var server=new BridgeServer(settings,new AntigravityBackend(settings),token,validator.ValidateAsync,models);
            await server.StartAsync().ConfigureAwait(false);
            Console.WriteLine(JsonSerializer.Serialize(new{component="aicli.gemini-responses",addresses=server.Addresses,pid=Environment.ProcessId}));
            await server.WaitAsync().ConfigureAwait(false);
            return 0;
        }
        catch(BridgeException e){Console.Error.WriteLine(e.Code);return 1;}
        catch(Exception e){Console.Error.WriteLine("gemini_bridge_start_failed:"+e.GetType().Name);return 1;}
    }
    public static void RecoverOwnedSessions(string runtime)
    {
        var storageRoot=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".gemini","antigravity-cli");
        foreach(var dir in Directory.EnumerateDirectories(runtime,"session_*",SearchOption.TopDirectoryOnly))
        {
            var name=Path.GetFileName(dir);
            if(!Guid.TryParseExact(name["session_".Length..],"N",out _))continue;
            OwnedStorage.AssertTreeNotReparse(dir);
            var marker=Path.Combine(dir,".aicli-owned-session.json");
            if(!File.Exists(marker)||JsonValueReader.Text(JsonNode.Parse(File.ReadAllText(marker)),"schema")!="aicli.gemini-session.v1")
                throw new BridgeException("unknown_session_directory",503);
            var journal=Path.Combine(dir,"owned-storage.json");
            if(File.Exists(journal))
            {
                var j=JsonNode.Parse(File.ReadAllText(journal));
                if(JsonValueReader.Text(j,"schema")!="aicli.antigravity-owned-storage.v1"||j?["conversation_ids"] is not JsonArray ids)
                    throw new BridgeException("owned_storage_journal_invalid",503);
                var storage=new OwnedStorage(storageRoot,journal);
                // Restore the complete deletion receipt atomically, never a shrinking prefix.
                var ownedIds=ids.Select(x=>x?.GetValue<string>()??throw new BridgeException("owned_storage_journal_invalid",503)).ToArray();
                storage.RememberAll(ownedIds);
                storage.Clean();
            }
            Directory.Delete(dir,true);
        }
    }
}
