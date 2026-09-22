# Pure model data validation. Never starts a model, resolves credentials or edits a deployment.
function Read-AiCliGeminiModelSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$SchemaPath)
    $raw=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    function Assert-UniqueJsonProperties([System.Text.Json.JsonElement]$Node) {
        if ($Node.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($p in $Node.EnumerateObject()){if(-not$names.Add($p.Name)){throw 'model_set_duplicate_property'};Assert-UniqueJsonProperties $p.Value}
        } elseif($Node.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){foreach($v in $Node.EnumerateArray()){Assert-UniqueJsonProperties $v}}
    }
    $doc=[System.Text.Json.JsonDocument]::Parse($raw)
    try{Assert-UniqueJsonProperties $doc.RootElement}finally{$doc.Dispose()}
    if(-not(Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction Stop)){throw 'model_set_schema_invalid'}
    $set=$raw|ConvertFrom-Json -AsHashtable -Depth 40
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $profiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $exact=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $menus=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($m in $set.models){
        if(-not$ids.Add($m.id)-or-not$profiles.Add($m.profileId)){throw 'model_set_duplicate_identity'}
        if([string]::IsNullOrWhiteSpace($m.displayName)){throw 'model_set_display_name_invalid'}
        $efforts=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $defaultFound=$false
        foreach($e in $m.efforts){
            if(-not$efforts.Add($e.effort)){throw 'model_set_duplicate_effort'}
            if($e.effort-ceq$m.defaultEffort-and$e.model-ceq$m.menuModel){$defaultFound=$true}
            if($exact.ContainsKey($e.model)-and$exact[$e.model]-cne$m.id){throw 'model_set_exact_identity_collision'}
            $exact[$e.model]=$m.id
        }
        if(-not$defaultFound){throw 'model_set_default_mapping_invalid'}
        [void]$menus.Add($m.menuModel)
    }
    if(-not$menus.Contains($set.defaultModel)){throw 'model_set_default_model_invalid'}
    return $set
}