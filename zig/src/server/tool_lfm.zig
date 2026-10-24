//! LFM2.5's tool calls, `<|tool_call_start|>[name(arg=value, ...)]<|tool_call_end|>`, as OpenAI tool_calls.
const std = @import("std");
const json = @import("json");
const ids = @import("ids.zig");
const reply_text = @import("reply_text.zig");
const tool_params = @import("tool_params.zig");
const tool_specs = @import("tool_specs.zig");
const Value = json.Value;
const Allocator = std.mem.Allocator;
const strip = reply_text.pyStrip;

const opener = "<|tool_call_start|>";
const closer = "<|tool_call_end|>";

const Call = struct { name: []const u8, arguments: Value };

pub const Parsed = struct { content: []const u8, calls: ?[]Value, rejected: usize = 0 };

/// Null when the text holds no LFM opener; otherwise the calls it makes and the text outside its envelopes.
pub fn parse(a: Allocator, text: []const u8, tools: []const Value, max_calls: ?usize) Allocator.Error!?Parsed {
    const first = std.mem.indexOf(u8, text, opener) orelse return null;
    var known: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (tools) |tool| {
        const name = try tool_specs.toolName(a, tool);
        if (name.len > 0) try known.put(a, try std.ascii.allocLowerString(a, name), name);
    }
    var calls: std.ArrayList(Value) = .empty;
    var residue: std.ArrayList(u8) = .empty;
    var rejected: usize = 0;
    var cursor: usize = 0;
    var pos = first;
    while (std.mem.indexOfPos(u8, text, pos, opener)) |s| {
        const e = std.mem.indexOfPos(u8, text, s + opener.len, closer) orelse {
            try residue.appendSlice(a, text[cursor..]);
            rejected += 1;
            cursor = text.len;
            break;
        };
        const end = e + closer.len;
        try residue.appendSlice(a, text[cursor..s]);
        cursor = end;
        pos = end;
        if (max_calls) |m| if (calls.items.len >= m) continue;
        const parsed = try callsIn(a, strip(text[s + opener.len .. e]), &known);
        const list = parsed orelse {
            try residue.appendSlice(a, text[s..end]);
            rejected += 1;
            continue;
        };
        for (list) |c| {
            if (max_calls) |m| if (calls.items.len >= m) break;
            try calls.append(a, try openaiCall(a, c.name, c.arguments));
        }
    }
    try residue.appendSlice(a, text[cursor..]);
    return .{ .content = strip(residue.items), .calls = if (calls.items.len > 0) calls.items else null, .rejected = rejected };
}

/// The parts of `s` between top-level `sep` bytes, outside strings and `([{` nesting.
const Parts = struct {
    s: []const u8,
    at: usize = 0,
    done: bool = false,
    bad: bool = false,

    /// The next part; null at the end or where a quote or bracket does not close (`bad`).
    fn next(p: *Parts, sep: u8) ?[]const u8 {
        if (p.done or p.bad) return null;
        var depth: usize = 0;
        var quote: u8 = 0;
        var escaped = false;
        var i = p.at;
        while (i < p.s.len) : (i += 1) {
            const ch = p.s[i];
            if (quote != 0) {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == quote) {
                    quote = 0;
                }
                continue;
            }
            switch (ch) {
                '\'', '"' => quote = ch,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => {
                    if (depth == 0) {
                        p.bad = true;
                        return null;
                    }
                    depth -= 1;
                },
                else => if (ch == sep and depth == 0) {
                    const part = strip(p.s[p.at..i]);
                    p.at = i + 1;
                    return part;
                },
            }
        }
        if (quote != 0 or depth != 0) {
            p.bad = true;
            return null;
        }
        p.done = true;
        return strip(p.s[p.at..]);
    }
};

/// One envelope's calls, or null when its payload is not `[name(args), ...]` or names a tool not offered.
fn callsIn(a: Allocator, payload: []const u8, known: *const std.StringArrayHashMapUnmanaged([]const u8)) Allocator.Error!?[]Call {
    if (payload.len < 2 or payload[0] != '[' or payload[payload.len - 1] != ']') return null;
    const list = strip(payload[1 .. payload.len - 1]);
    if (list.len == 0) return null;
    var calls: std.ArrayList(Call) = .empty;
    var parts: Parts = .{ .s = list };
    while (parts.next(',')) |piece| {
        const c = (try call(a, piece, known)) orelse return null;
        try calls.append(a, c);
    }
    if (parts.bad) return null;
    return calls.items;
}

/// One `name(arg=value, ...)`; null when it is not one or names a tool the request did not offer.
fn call(a: Allocator, piece: []const u8, known: *const std.StringArrayHashMapUnmanaged([]const u8)) Allocator.Error!?Call {
    const open = std.mem.indexOfScalar(u8, piece, '(') orelse return null;
    const name = strip(piece[0..open]);
    if (name.len == 0) return null;
    const offered = known.get(try std.ascii.allocLowerString(a, name)) orelse return null;
    const tail = strip(piece[open + 1 ..]);
    if (tail.len == 0 or tail[tail.len - 1] != ')') return null;
    const body = strip(tail[0 .. tail.len - 1]);
    const arguments = try json.newObject(a);
    if (body.len > 0) {
        var parts: Parts = .{ .s = body };
        while (parts.next(',')) |arg| {
            const eq = topIndex(arg, '=') orelse return null;
            const key = strip(arg[0..eq]);
            if (key.len == 0) return null;
            try arguments.put(a, key, (try argument(a, strip(arg[eq + 1 ..]))) orelse return null);
        }
        if (parts.bad) return null;
    }
    return .{ .name = offered, .arguments = .{ .object = arguments } };
}

/// The first top-level `sep` outside strings and brackets, or null.
fn topIndex(s: []const u8, sep: u8) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (s, 0..) |ch, i| {
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == quote) {
                quote = 0;
            }
            continue;
        }
        switch (ch) {
            '\'', '"' => quote = ch,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            else => if (ch == sep and depth == 0) return i,
        }
    }
    return null;
}

/// The model's typed value: JSON first (the template's `tojson`), then Python's spelling (`True`, `None`, lists).
fn argument(a: Allocator, raw: []const u8) Allocator.Error!?Value {
    if (raw.len == 0) return null;
    switch (try json.parseText(a, raw)) {
        .ok => |v| return if (tool_params.finite(v)) v else null,
        .err => {},
    }
    const v = (try tool_params.pythonLiteral(a, raw)) orelse return null;
    return if (tool_params.finite(v)) v else null;
}

/// The OpenAI call object under the offered name, arguments as compact JSON.
fn openaiCall(a: Allocator, name: []const u8, arguments: Value) Allocator.Error!Value {
    const function = try json.newObject(a);
    try function.put(a, "name", .{ .string = name });
    try function.put(a, "arguments", .{ .string = try json.stringify(a, arguments, .{ .ascii = false, .compact = true }) });
    const out = try json.newObject(a);
    try out.put(a, "id", .{ .string = try ids.make(a, "call_", 24) });
    try out.put(a, "type", .{ .string = "function" });
    try out.put(a, "function", .{ .object = function });
    return .{ .object = out };
}
