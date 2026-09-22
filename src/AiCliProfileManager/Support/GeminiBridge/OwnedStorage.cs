using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace AiCli.GeminiBridge;

// These identifiers are a deletion receipt only, never a conversation/history
// authority. The bridge never reads or copies Antigravity OAuth credentials.
public sealed class OwnedStorage(string antigravityRoot, string journalPath)
{
    private readonly HashSet<string> ids=new(StringComparer.Ordinal);
    public void Remember(string id) => RememberAll([id]);
    public void RememberAll(IEnumerable<string> ownedIds)
    {
        var merged = new HashSet<string>(ids, StringComparer.Ordinal);
        foreach (var id in ownedIds)
        {
            if (!Guid.TryParseExact(id, "D", out var guid) || guid == Guid.Empty)
                throw new BridgeException("invalid_backend_session_identity", 502);
            merged.Add(id);
        }
        if (merged.SetEquals(ids)) return;
        var bytes = new JsonObject
        {
            ["schema"] = "aicli.antigravity-owned-storage.v1",
            ["conversation_ids"] = new JsonArray(merged.Select(x => (JsonNode)JsonValue.Create(x)!).ToArray())
        }.ToJsonString();
        File.WriteAllText(journalPath + ".new", bytes, new UTF8Encoding(false));
        File.Move(journalPath + ".new", journalPath, true);
        ids.UnionWith(merged);
    }
    public void Clean()
    {
        foreach(var id in ids)CleanOne(id);
        ids.Clear();if(File.Exists(journalPath))File.Delete(journalPath);
    }
    private void CleanOne(string id)
    {
        var dbPath=Path.Combine(antigravityRoot,"conversations",id+".db");
        AssertNotReparse(dbPath);
        if(File.Exists(dbPath))
        {
            using var db=new ExistingSqlite(dbPath,readOnly:true);
            var rows=db.Query("SELECT trajectory_id,cascade_id FROM trajectory_meta");
            if(rows.Count==0 || rows.Any(row=>!row.Contains(id,StringComparer.Ordinal)))throw new BridgeException("owned_session_identity_mismatch",503);
        }
        var summaryPath=Path.Combine(antigravityRoot,"conversation_summaries.db");
        if(File.Exists(summaryPath))
        {
            AssertNotReparse(summaryPath);
            using var db=new ExistingSqlite(summaryPath,readOnly:false);
            db.Execute("BEGIN IMMEDIATE");
            try{db.Execute("DELETE FROM conversation_summaries WHERE conversation_id=?",id);db.Execute("COMMIT");}
            catch{db.Execute("ROLLBACK");throw;}
        }
        var mapPath=Path.Combine(antigravityRoot,"jetbox_summaries_proto.pb");
        if(File.Exists(mapPath))RemoveMapEntry(mapPath,id);
        foreach(var relative in new[]{Path.Combine("brain",id),Path.Combine("annotations",id+".pbtxt"),Path.Combine("conversations",id+".db"),Path.Combine("conversations",id+".db-wal"),Path.Combine("conversations",id+".db-shm")})
        {
            var path=Path.Combine(antigravityRoot,relative);AssertNotReparse(path);
            if(Directory.Exists(path)){AssertTreeNotReparse(path);Directory.Delete(path,true);}else if(File.Exists(path))File.Delete(path);
            if(File.Exists(path)||Directory.Exists(path))throw new BridgeException("owned_session_cleanup_incomplete",503);
        }
    }
    public static void AssertNotReparse(string path)
    {
        if((File.Exists(path)||Directory.Exists(path)) && (File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)
            throw new BridgeException("owned_storage_reparse_point",503);
    }
    public static void AssertTreeNotReparse(string path)
    {
        AssertNotReparse(path);
        foreach(var child in Directory.EnumerateFileSystemEntries(path))
        {AssertNotReparse(child);if(Directory.Exists(child))AssertTreeNotReparse(child);}
    }
    private static void RemoveMapEntry(string path,string id)
    {
        AssertNotReparse(path);
        using var file=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None);
        if(file.Length>64*1024*1024)throw new BridgeException("summary_index_too_large",503);
        var before=new byte[(int)file.Length];file.ReadExactly(before);var after=FilterMap(before,id);
        if(before.AsSpan().SequenceEqual(after))return;
        try
        {
            file.Position=0;file.Write(after);file.SetLength(after.Length);file.Flush(true);file.Position=0;
            var check=new byte[after.Length];file.ReadExactly(check);if(!check.AsSpan().SequenceEqual(after))throw new IOException("index_readback_failed");
        }
        catch{file.Position=0;file.Write(before);file.SetLength(before.Length);file.Flush(true);throw;}
    }
    public static byte[] FilterMap(byte[] bytes,string ownedId)
    {
        if(!Guid.TryParseExact(ownedId,"D",out _))throw new ArgumentException("invalid_id",nameof(ownedId));
        var key=Encoding.UTF8.GetBytes(ownedId);using var output=new MemoryStream();
        foreach(var field in Fields(bytes))
        {
            var data=bytes.AsSpan(field.PayloadStart,field.PayloadLength);
            if(field.Number==1 && field.Wire==2)
            {
                var nested=Fields(data.ToArray()).ToArray();
                var keys=nested.Where(f=>f.Number==1&&f.Wire==2).ToArray();
                if(keys.Length==1 && data.Slice(keys[0].PayloadStart,keys[0].PayloadLength).SequenceEqual(key))
                {
                    if(nested.Length!=2 || nested[1].Number!=2 || nested[1].Wire!=2)throw new BridgeException("summary_map_shape_changed",503);
                    continue;
                }
            }
            output.Write(bytes,field.Start,field.End-field.Start);
        }
        return output.ToArray();
    }
    private sealed record Field(int Number,int Wire,int Start,int End,int PayloadStart,int PayloadLength);
    private static IEnumerable<Field> Fields(byte[] bytes)
    {
        var i=0;
        while(i<bytes.Length)
        {
            var start=i;var tag=Varint(bytes,ref i);var wire=(int)(tag&7);var number=checked((int)(tag>>3));
            if(number==0)throw new BridgeException("invalid_summary_map",503);
            int payloadStart,payloadLength;
            switch(wire)
            {
                case 0:payloadStart=i;Varint(bytes,ref i);payloadLength=i-payloadStart;break;
                case 1:payloadStart=i;payloadLength=8;i=checked(i+8);break;
                case 5:payloadStart=i;payloadLength=4;i=checked(i+4);break;
                case 2:payloadLength=checked((int)Varint(bytes,ref i));payloadStart=i;i=checked(i+payloadLength);break;
                default:throw new BridgeException("unsupported_summary_map_wire_type",503);
            }
            if(i>bytes.Length)throw new BridgeException("truncated_summary_map",503);
            yield return new Field(number,wire,start,i,payloadStart,payloadLength);
        }
    }
    private static ulong Varint(byte[] b,ref int i)
    {
        ulong value=0;
        for(var shift=0;shift<70;shift+=7)
        {
            if(i>=b.Length)throw new BridgeException("truncated_summary_varint",503);
            var n=b[i++];if(shift==63&&(n&0xFE)!=0)throw new BridgeException("invalid_summary_varint",503);
            value|=(ulong)(n&127)<<shift;if(n<128)return value;
        }
        throw new BridgeException("invalid_summary_varint",503);
    }
}

internal sealed class ExistingSqlite:IDisposable
{
    private IntPtr db;
    public ExistingSqlite(string path,bool readOnly)
    {
        if(sqlite3_open_v2(path,out db,readOnly?1:2,IntPtr.Zero)!=0){if(db!=IntPtr.Zero)sqlite3_close_v2(db);db=IntPtr.Zero;throw new BridgeException("owned_database_unavailable",503);}
        sqlite3_busy_timeout(db,3000);
    }
    public void Execute(string sql,string? parameter=null)
    {
        var statement=Prepare(sql,parameter);
        try{if(sqlite3_step(statement)!=101)throw new BridgeException("owned_database_write_failed",503);}
        finally{sqlite3_finalize(statement);}
    }
    public List<string[]> Query(string sql)
    {
        var statement=Prepare(sql,null);var rows=new List<string[]>();
        try
        {
            int code;
            while((code=sqlite3_step(statement))==100)
            {
                var row=new string[sqlite3_column_count(statement)];
                for(var i=0;i<row.Length;i++)row[i]=Marshal.PtrToStringUTF8(sqlite3_column_text(statement,i))??"";
                rows.Add(row);
            }
            if(code!=101)throw new BridgeException("owned_database_read_failed",503);return rows;
        }
        finally{sqlite3_finalize(statement);}
    }
    private IntPtr Prepare(string sql,string? parameter)
    {
        if(sqlite3_prepare_v2(db,sql,-1,out var statement,IntPtr.Zero)!=0)throw new BridgeException("owned_database_schema_changed",503);
        if(parameter is not null && sqlite3_bind_text(statement,1,parameter,-1,new IntPtr(-1))!=0){sqlite3_finalize(statement);throw new BridgeException("owned_database_bind_failed",503);}
        return statement;
    }
    public void Dispose(){if(db!=IntPtr.Zero){sqlite3_close_v2(db);db=IntPtr.Zero;}}
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)]string path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_close_v2(IntPtr db);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_busy_timeout(IntPtr db,int ms);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_prepare_v2(IntPtr db,[MarshalAs(UnmanagedType.LPUTF8Str)]string sql,int n,out IntPtr stmt,IntPtr tail);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_bind_text(IntPtr stmt,int index,[MarshalAs(UnmanagedType.LPUTF8Str)]string value,int n,IntPtr destructor);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]private static extern IntPtr sqlite3_column_text(IntPtr stmt,int index);
}
