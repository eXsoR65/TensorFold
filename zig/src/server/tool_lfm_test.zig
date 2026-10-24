//! LFM2.5 envelopes: typed arguments, several calls, offered names, and the text around them.
const std = @import("std");
const json = @import("json");
const reply_text = @import("reply_text.zig");
const tool_lfm = @import("tool_lfm.zig");
const tool_parse = @import("tool_parse.zig");
const parse = tool_parse.parse;

const declared =
    \\[{"type":"function","function":{"name":"get_weather","parameters":{"properties":{"city":{"type":"string"}}}}},
    \\ {"type":"function","function":{"name":"get_time"}},
    \\ {"type":"function","function":{"name":"search"}},
    \\ {"type":"function","function":{"name":"flag"}},
    \\ {"type":"function","function":{"name":"echo"}},
    \\ {"type":"function","function":{"name":"filter"}}]
;

fn offered(a: std.mem.Allocator) ![]json.Value {
    return (try json.parse(a, declared)).ok.array;
}

fn arguments(call: json.Value) []const u8 {
    return call.get("function").?.get("arguments").?.string;
}

fn nameOf(call: json.Value) []const u8 {
    return call.get("function").?.get("name").?.string;
}

test "LFM envelopes become calls with the model's argument types" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try offered(a);
    const cases = [_][3][]const u8{ // the envelope, the offered name, the compact arguments
        .{ "<|tool_call_start|>[get_weather(city='Paris')]<|tool_call_end|>", "get_weather", "{\"city\":\"Paris\"}" },
        .{ "<|tool_call_start|>[search(limit=5, ratio=0.5, exact=True)]<|tool_call_end|>", "search", "{\"limit\":5,\"ratio\":0.5,\"exact\":true}" },
        .{ "<|tool_call_start|>[flag(on=True, off=False, empty=None)]<|tool_call_end|>", "flag", "{\"on\":true,\"off\":false,\"empty\":null}" },
        .{ "<|tool_call_start|>[echo(text='a\\'b, c')]<|tool_call_end|>", "echo", "{\"text\":\"a'b, c\"}" },
        .{ "<|tool_call_start|>[filter(tags=['a','b'], opts={\"case\":false, \"none\":null})]<|tool_call_end|>", "filter", "{\"tags\":[\"a\",\"b\"],\"opts\":{\"case\":false,\"none\":null}}" },
        .{ "<|tool_call_start|>[filter(tags=[None, True], opts={'case': False})]<|tool_call_end|>", "filter", "{\"tags\":[null,true],\"opts\":{\"case\":false}}" },
        .{ "<|tool_call_start|>[get_time()]<|tool_call_end|>", "get_time", "{}" },
        .{ "<|tool_call_start|>[GET_WEATHER(city='Paris')]<|tool_call_end|>", "get_weather", "{\"city\":\"Paris\"}" },
    };
    for (cases) |c| {
        const r = try parse(a, c[0], tools, null);
        try std.testing.expectEqual(@as(usize, 1), r.calls.?.len);
        try std.testing.expectEqualStrings(c[1], nameOf(r.calls.?[0]));
        try std.testing.expectEqualStrings(c[2], arguments(r.calls.?[0]));
        try std.testing.expectEqualStrings("", r.content);
        try std.testing.expectEqual(@as(usize, 0), r.rejected_envelopes);
    }
}

test "one envelope holds several calls and the text around them stays" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try offered(a);
    const text = "before <|tool_call_start|>[\n  get_weather( city = 'Paris' ),\n  get_time(city='Paris')\n]<|tool_call_end|> after";
    const r = try parse(a, text, tools, null);
    try std.testing.expectEqual(@as(usize, 2), r.calls.?.len);
    try std.testing.expectEqualStrings("get_weather", nameOf(r.calls.?[0]));
    try std.testing.expectEqualStrings("get_time", nameOf(r.calls.?[1]));
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", arguments(r.calls.?[0]));
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", arguments(r.calls.?[1]));
    try std.testing.expectEqualStrings("before  after", r.content);
    const between = "Hi <|tool_call_start|>[get_weather(city='Paris')]<|tool_call_end|> and " ++
        "<|tool_call_start|>[get_time()]<|tool_call_end|>.";
    const more = try parse(a, between, tools, null);
    try std.testing.expectEqual(@as(usize, 2), more.calls.?.len);
    try std.testing.expectEqualStrings("Hi  and .", more.content);
}

test "unoffered and malformed envelopes stay content and are counted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try offered(a);
    const cases = [_][]const u8{
        "<|tool_call_start|>[nope(x=1)]<|tool_call_end|>",
        "bad <|tool_call_start|>[nope(x=1)]<|tool_call_end|>",
        "<|tool_call_start|>[get_weather(city='Paris']<|tool_call_end|>",
        "<|tool_call_start|>[get_weather(city='Paris')<|tool_call_end|>",
        "<|tool_call_start|>[get_weather(city)]<|tool_call_end|>",
        "<|tool_call_start|>[]<|tool_call_end|>",
        "<|tool_call_start|>[get_weather(city='Paris')]",
    };
    for (cases) |text| {
        const r = try parse(a, text, tools, null);
        try std.testing.expect(r.calls == null);
        try std.testing.expectEqualStrings(text, r.content);
        try std.testing.expectEqual(@as(usize, 1), r.rejected_envelopes);
    }
    const twice = "<|tool_call_start|>[nope(x=1)]<|tool_call_end|> " ++
        "<|tool_call_start|>[nope(y=2)]<|tool_call_end|>";
    const r = try parse(a, twice, tools, null);
    try std.testing.expect(r.calls == null);
    try std.testing.expectEqualStrings(twice, r.content);
    try std.testing.expectEqual(@as(usize, 2), r.rejected_envelopes);
    // one unoffered call rejects the whole envelope, as every other format's envelope does
    const mixed = "<|tool_call_start|>[get_weather(city='Paris'), nope(x=1)]<|tool_call_end|>";
    const mixed_r = try parse(a, mixed, tools, null);
    try std.testing.expect(mixed_r.calls == null);
    try std.testing.expectEqualStrings(mixed, mixed_r.content);
    try std.testing.expectEqual(@as(usize, 1), mixed_r.rejected_envelopes);
}

test "max_calls keeps the request's limit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try offered(a);
    const text = "<|tool_call_start|>[get_weather(city='Paris'), get_time(city='Paris')]<|tool_call_end|>";
    const one = try parse(a, text, tools, 1);
    try std.testing.expectEqual(@as(usize, 1), one.calls.?.len);
    try std.testing.expectEqualStrings("get_weather", nameOf(one.calls.?[0]));
    try std.testing.expectEqualStrings("", one.content);
    const envelopes = text ++ "<|tool_call_start|>[get_time()]<|tool_call_end|>";
    const limited = try parse(a, envelopes, tools, 1);
    try std.testing.expectEqual(@as(usize, 1), limited.calls.?.len);
    try std.testing.expectEqualStrings("", limited.content);
    const all = try parse(a, envelopes, tools, null);
    try std.testing.expectEqual(@as(usize, 3), all.calls.?.len);
    const rejected_first = "<|tool_call_start|>[nope(x=1)]<|tool_call_end|>" ++ text;
    const kept = try parse(a, rejected_first, tools, 1);
    try std.testing.expectEqual(@as(usize, 1), kept.calls.?.len);
    try std.testing.expectEqualStrings("<|tool_call_start|>[nope(x=1)]<|tool_call_end|>", kept.content);
}

test "LFM parsing leaves other formats and ordinary prose to the existing parser" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try offered(a);
    const legacy = "<tool_call>{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}</tool_call>";
    const r = try parse(a, legacy, tools, null);
    try std.testing.expectEqual(@as(usize, 1), r.calls.?.len);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", arguments(r.calls.?[0]));
    try std.testing.expect((try tool_lfm.parse(a, legacy, tools, null)) == null);
    try std.testing.expect((try tool_lfm.parse(a, "ordinary prose", tools, null)) == null);
    const prose = try parse(a, "ordinary prose", tools, null);
    try std.testing.expect(prose.calls == null);
    try std.testing.expectEqualStrings("ordinary prose", prose.content);
}

test "streamed prose hides LFM envelopes and the deltas carry the calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try offered(a);
    const text = "Hi <|tool_call_start|>[get_weather(city='Paris')]<|tool_call_end|>";
    try std.testing.expectEqualStrings("Hi ", try reply_text.hideToolCalls(a, text, false));
    try std.testing.expectEqualStrings("Hi", try reply_text.finishedProse(a, text));
    const r = try parse(a, text, tools, null);
    const deltas = try tool_parse.deltas(a, r.calls.?);
    try std.testing.expectEqual(@as(usize, 2), deltas.len);
    const head = deltas[0].get("tool_calls").?.array[0].get("function").?;
    try std.testing.expectEqualStrings("get_weather", head.get("name").?.string);
    try std.testing.expectEqualStrings("", head.get("arguments").?.string);
    const more = deltas[1].get("tool_calls").?.array[0].get("function").?;
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", more.get("arguments").?.string);
}
