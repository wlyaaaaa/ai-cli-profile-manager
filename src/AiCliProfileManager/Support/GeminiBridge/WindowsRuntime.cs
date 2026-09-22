using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace AiCli.GeminiBridge;

public static class ChildEnvironment
{
    private static readonly Regex Removed = new("^(OPENAI|ANTHROPIC|CODEX|AICLI|GEMINI|GOOGLE|VERTEX|GCLOUD|CLOUDSDK|DEEPSEEK|DASHSCOPE|ZHIPU|GLM|QWEN|AGENTS)(_|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    public static void Scrub(ProcessStartInfo info, string temp, string powerShellPath)
    {
        foreach(var name in info.Environment.Keys.ToArray()) if(Removed.IsMatch(name)) info.Environment.Remove(name);
        foreach(var name in new[]{"TEMP","TMP","TMPDIR"})info.Environment[name]=temp;
        info.Environment["PATH"]=Path.GetDirectoryName(powerShellPath)+Path.PathSeparator+(info.Environment.TryGetValue("PATH", out var currentPath) ? currentPath : "");
    }
    public static ProcessStartInfo Redirected(string executable) => new(executable)
    {
        UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,
        StandardInputEncoding=new UTF8Encoding(false),StandardOutputEncoding=new UTF8Encoding(false),StandardErrorEncoding=new UTF8Encoding(false)
    };
    public static void Kill(Process process)
    {
        try{if(!process.HasExited)process.Kill(entireProcessTree:true);}catch(InvalidOperationException){}catch(Win32Exception){}
    }
}

public sealed class NativeJob : IDisposable
{
    private readonly JobHandle handle;
    private NativeJob(JobHandle handle)=>this.handle=handle;
    public static NativeJob Attach(Process process)
    {
        var handle=CreateJobObjectW(IntPtr.Zero,null);
        if(handle.IsInvalid){handle.Dispose();throw new BridgeException("process_lifetime_unavailable",503);}
        try
        {
            var limits=new ExtendedLimits();limits.Basic.LimitFlags=0x2000;
            var length=Marshal.SizeOf<ExtendedLimits>();var ptr=Marshal.AllocHGlobal(length);
            try{Marshal.StructureToPtr(limits,ptr,false);if(!SetInformationJobObject(handle,9,ptr,(uint)length))throw new Win32Exception(Marshal.GetLastWin32Error());}
            finally{Marshal.FreeHGlobal(ptr);}
            if(!AssignProcessToJobObject(handle,process.Handle))throw new Win32Exception(Marshal.GetLastWin32Error());
            return new NativeJob(handle);
        }
        catch{handle.Dispose();ChildEnvironment.Kill(process);throw;}
    }
    public void Dispose()=>handle.Dispose();
    private sealed class JobHandle:SafeHandleZeroOrMinusOneIsInvalid
    {
        private JobHandle():base(true){}
        protected override bool ReleaseHandle()=>CloseHandle(handle);
    }
    [StructLayout(LayoutKind.Sequential)]private struct BasicLimits
    {
        public long ProcessTime,JobTime;public uint LimitFlags;public UIntPtr MinWorkingSet,MaxWorkingSet;
        public uint ActiveProcessLimit;public UIntPtr Affinity;public uint PriorityClass,SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]private struct Counters{public ulong ReadOps,WriteOps,OtherOps,ReadBytes,WriteBytes,OtherBytes;}
    [StructLayout(LayoutKind.Sequential)]private struct ExtendedLimits
    {public BasicLimits Basic;public Counters Io;public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern JobHandle CreateJobObjectW(IntPtr attrs,string? name);
    [DllImport("kernel32.dll",SetLastError=true)]private static extern bool SetInformationJobObject(JobHandle job,int cls,IntPtr info,uint len);
    [DllImport("kernel32.dll",SetLastError=true)]private static extern bool AssignProcessToJobObject(JobHandle job,IntPtr process);
    [DllImport("kernel32.dll")]private static extern bool CloseHandle(IntPtr handle);
}

// Reuse PowerShell's shipped JSON Schema validator rather than maintaining a
// partial, permissive schema implementation or adding a second dependency tree.
// Schema and instance are supplied over stdin, never argv or a temporary file.
public sealed class PowerShellSchemaValidator(string executable, string temp)
{
    private const string Script="""
        $ErrorActionPreference='Stop'
        try {
            $packet=[Console]::In.ReadToEnd()|ConvertFrom-Json -AsHashtable -Depth 100
            $valid=Test-Json -Json ($packet.instance|ConvertTo-Json -Depth 100 -Compress) -Schema ($packet.schema|ConvertTo-Json -Depth 100 -Compress) -ErrorAction SilentlyContinue
            [Console]::WriteLine($(if($valid){'true'}else{'false'}))
        } catch { [Console]::WriteLine('false') }
        """;
    public async Task<bool> ValidateAsync(JsonObject schema,JsonNode instance,CancellationToken token)
    {
        RejectExternalReferences(schema);
        var start=ChildEnvironment.Redirected(executable);ChildEnvironment.Scrub(start,temp,executable);
        foreach(var arg in new[]{"-NoLogo","-NoProfile","-NonInteractive","-EncodedCommand",Convert.ToBase64String(Encoding.Unicode.GetBytes(Script))})start.ArgumentList.Add(arg);
        using var process=Process.Start(start)??throw new BridgeException("schema_validator_unavailable",503);
        using var job=NativeJob.Attach(process);
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var cancel=timeout.Token.Register(()=>ChildEnvironment.Kill(process));
        var stdout=process.StandardOutput.ReadToEndAsync(timeout.Token);var stderr=process.StandardError.ReadToEndAsync(timeout.Token);
        var payload=new JsonObject{["schema"]=schema.DeepClone(),["instance"]=instance.DeepClone()}.ToJsonString();
        await process.StandardInput.WriteAsync(payload.AsMemory(),timeout.Token).ConfigureAwait(false);process.StandardInput.Close();
        await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        var text=await stdout.ConfigureAwait(false);await stderr.ConfigureAwait(false);
        return process.ExitCode==0 && text.Trim()=="true";
    }
    private static void RejectExternalReferences(JsonNode? node)
    {
        if(node is JsonObject obj)
            foreach(var (key,value) in obj)
            {
                if(key is "$ref" or "$dynamicRef" && value is JsonValue v && v.TryGetValue<string>(out var text) && !text.StartsWith('#'))
                    throw new BridgeException("external_schema_reference_not_supported");
                RejectExternalReferences(value);
            }
        else if(node is JsonArray array)foreach(var child in array)RejectExternalReferences(child);
    }
}
