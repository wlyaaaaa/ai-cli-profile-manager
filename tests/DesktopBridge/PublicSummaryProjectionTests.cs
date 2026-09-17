using System.Text.Json.Nodes;

internal static class PublicSummaryProjectionTests
{
    private static JsonObject Note(string method, JsonObject? item = null, string thread = "t", string turn = "u") => new()
    {
        ["method"] = method,
        ["params"] = new JsonObject { ["threadId"] = thread, ["turnId"] = turn, ["item"] = item }
    };
    private static JsonObject Message(string id, string text, string? phase = null) => new()
    { ["id"] = id, ["type"] = "agentMessage", ["text"] = text, ["phase"] = phase };
    private static string[] Deltas(IEnumerable<JsonObject> output) => output
        .Where(x => x["method"]?.GetValue<string>() == "item/reasoning/summaryTextDelta")
        .Select(x => x["params"]!["delta"]!.GetValue<string>()).ToArray();

    public static void Run(Action<bool, string> check)
    {
        var projector = new PublicSummaryProjection();
        var raw = Note("item/reasoning/textDelta");
        raw["params"]!["itemId"] = "raw-1";
        raw["params"]!["delta"] = "PRIVATE_REASONING_CANARY";
        var originalRaw = raw.ToJsonString();
        check(projector.Normalize(raw, "t").Count == 0, "Raw reasoning must not masquerade as a public summary.");
        check(raw.ToJsonString() == originalRaw, "Display filtering must not mutate upstream reasoning data.");

        var nativeStart = Note("item/started", new JsonObject
        { ["type"] = "reasoning", ["id"] = "native-start", ["summary"] = new JsonArray("RAW_CANARY"), ["content"] = new JsonArray("RAW_CANARY") });
        var originalStart = nativeStart.ToJsonString();
        var structural = projector.Normalize(nativeStart, "t").Single();
        check(structural["params"]!["item"]!["id"]!.GetValue<string>() == "native-start", "Keep real lifecycle identity for continuity.");
        check(!structural.ToJsonString().Contains("RAW_CANARY") && nativeStart.ToJsonString() == originalStart, "Strip content only in the UI clone, never the upstream item.");
        var progress = Note("item/completed", Message("m1", "查到四个文件尚未备份，先不能删除原件。", "commentary"));
        var originalProgress = progress.ToJsonString();
        var output = projector.Normalize(progress, "t");
        check(Deltas(output).SequenceEqual(new[] { "查到四个文件尚未备份，先不能删除原件。" }), "Use the exact public message, without rewriting or model calls.");
        check(progress.ToJsonString() == originalProgress && output.Contains(progress), "Keep the original public transcript message intact.");
        check(output.Any(x => x["params"]?["item"]?["id"]?.GetValue<string>() == PublicSummaryProjection.ItemPrefix + "m1"), "Use a distinct synthetic item identity, not a real message ID.");
        check(Deltas(projector.Normalize(progress, "t")).Length == 0, "Duplicate completion must not duplicate the summary.");

        var final = Note("item/completed", Message("final", "最终答案：不要删除。", "final_answer"));
        var originalFinal = final.ToJsonString();
        check(Deltas(projector.Normalize(final, "t")).Length == 0 && final.ToJsonString() == originalFinal, "An explicit final answer must never be repurposed as a summary.");
        var followingTool = Note("item/started", new JsonObject { ["type"] = "dynamicToolCall", ["id"] = "tool" });
        check(Deltas(projector.Normalize(followingTool, "t")).Length == 0, "Even a later tool must not reclassify an explicit final.");

        var unphased = Note("item/completed", Message("glm-progress", "任务正常退出不等于备份齐全。"), "g", "v");
        check(Deltas(projector.Normalize(unphased, "g")).Length == 0, "Do not guess the role of an unphased GLM message.");
        var tool = Note("item/started", new JsonObject { ["type"] = "dynamicToolCall", ["id"] = "tool2" }, "g", "v");
        check(Deltas(projector.Normalize(tool, "g")).SequenceEqual(new[] { "任务正常退出不等于备份齐全。" }), "A following real tool identifies a phase-less public progress message.");
        var unphasedFinal = Note("item/completed", Message("glm-final", "已经查明遗漏四个文件。"), "g", "v");
        projector.Normalize(unphasedFinal, "g");
        var terminal = Note("turn/completed", null, "g", "v");
        var closed = projector.Normalize(terminal, "g");
        check(Deltas(closed).Length == 0 && ReferenceEquals(closed.Last(), terminal), "Turn completion must not copy an unphased final into the summary.");
        check(closed.Any(x => x["method"]?.GetValue<string>() == "item/completed" && x["params"]?["item"]?["id"]?.GetValue<string>() == PublicSummaryProjection.ItemPrefix + "glm-progress"), "Close generated reasoning items before the terminal event.");
        check(projector.Normalize(terminal, "g").Count == 1, "Terminal cleanup must be idempotent.");
        var other = Note("item/started", new JsonObject { ["type"] = "dynamicToolCall", ["id"] = "other-tool" }, "other", "u");
        check(Deltas(projector.Normalize(other, "other")).Length == 0, "Never reuse another thread's pending progress.");

        var finalHistory = Message("hist-final", "保留最终答复原文。", "final_answer");
        var originalFinalHistory = finalHistory.ToJsonString();
        var history = new JsonObject { ["turns"] = new JsonArray(new JsonObject { ["items"] = new JsonArray(
            new JsonObject { ["type"] = "reasoning", ["id"] = "native", ["content"] = new JsonArray("PRIVATE_REASONING_CANARY"), ["summary"] = new JsonArray() },
            Message("hist-progress", "先检查实际备份数量。"),
            new JsonObject { ["type"] = "commandExecution", ["id"] = "hist-tool" },
            finalHistory) }) };
        var sourceHistory = history.DeepClone();
        PublicSummaryProjection.ProjectHistory(history);
        var historyItems = history["turns"]![0]!["items"]!.AsArray();
        check(historyItems.OfType<JsonObject>().Count(x => x["type"]?.GetValue<string>() == "reasoning") == 1, "Rebuild only the public summary in projected history.");
        check(!history.ToJsonString().Contains("PRIVATE_REASONING_CANARY"), "Do not expose raw reasoning under a summary heading in projected history.");
        check(sourceHistory.ToJsonString().Contains("PRIVATE_REASONING_CANARY"), "The independent upstream history remains untouched.");
        check(historyItems.OfType<JsonObject>().Single(x => x["id"]?.GetValue<string>() == "hist-final").ToJsonString() == originalFinalHistory, "Preserve final-answer history exactly.");
        var once = history.ToJsonString();
        PublicSummaryProjection.ProjectHistory(history);
        check(history.ToJsonString() == once, "History reconstruction must not accumulate synthetic duplicates.");
        var partialPage = new JsonObject { ["items"] = new JsonArray(Message("uncertain", "A phase-less page boundary message")) };
        var partialOriginal = partialPage.ToJsonString();
        PublicSummaryProjection.ProjectHistory(partialPage);
        check(partialPage.ToJsonString() == partialOriginal, "Do not infer a final/progress distinction across an unknown page boundary.");

        var cancelledProgress = Note("item/completed", Message("cancel-progress", "检查尚未完成。", "commentary"), "c", "cancel");
        projector.Normalize(cancelledProgress, "c");
        foreach (var method in new[] { "turn/cancelled", "turn/failed" })
        {
            var cancelled = Note(method, null, "c", "cancel");
            var result = projector.Normalize(cancelled, "c");
            check(ReferenceEquals(result.Last(), cancelled), "Preserve failure/cancellation and close the summary instead of claiming success.");
        }
    }
}
