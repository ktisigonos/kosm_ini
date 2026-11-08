//! Reads INI into the tree kosm matches paths against (D30, D106), the way a `Dialect` says.
//! Hand-written (D40): every line is blank, a comment, a `[section]` header or `key = value`,
//! and a key belongs to the header above it. The tree is the file's meaning: a section spelled
//! twice is one table, `[A][B]` is table B inside A, and a key written twice is two entries, so
//! `set` refuses to pick one (D31).

const Parser = @This();

const std = @import("std");
const kosm = @import("kosm");
const Dialect = @import("Dialect.zig");
const Node = kosm.Adapter.Node;
const Range = kosm.Adapter.Range;

allocator: std.mem.Allocator,
source: []const u8,
context: *kosm.Adapter.Context,
dialect: *const Dialect,

const Error = kosm.Adapter.ParseError;

/// A node while the file is read: sections still grow as later headers add to them.
const Draft = struct {
    key: ?[]const u8,
    position: usize,
    kind: Node.Kind,
    value: ?Range,
    children: std.ArrayList(*Draft) = .empty,
};

/// One line's text, spaces trimmed on both sides, and where it starts in the file.
const Line = struct {
    start: usize,
    text: []const u8,
};

/// An adapter `parser` for `dialect`: the file as one table. Nodes point into `source`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, context: *kosm.Adapter.Context, dialect: *const Dialect) Error!Node {
    var parser: Parser = .{ .allocator = allocator, .source = source, .context = context, .dialect = dialect };
    const root = try parser.newDraft(.{ .key = null, .position = 0, .kind = .table, .value = .{ .start = 0, .end = source.len } });
    var current: ?*Draft = null;
    var index: usize = 0;
    while (index < source.len) {
        const end = std.mem.findScalarPos(u8, source, index, '\n') orelse source.len;
        const line = trim(source, index, end);
        index = end + 1;
        if (line.text.len == 0 or parser.isComment(line.text)) continue;
        if (line.text[0] == '[') {
            current = try parser.header(root, line);
        } else {
            if (current == null and !dialect.top_level_keys)
                return parser.fail(line.start, "a key before the first [section], which {s} files don't allow", .{dialect.name});
            try parser.pair(current orelse root, line);
        }
    }
    return parser.freeze(root);
}

fn trim(source: []const u8, start: usize, end: usize) Line {
    var first = start;
    var last = end;
    while (first < last and isSpace(source[first])) first += 1;
    while (last > first and (isSpace(source[last - 1]) or source[last - 1] == '\r')) last -= 1;
    return .{ .start = first, .text = source[first..last] };
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isComment(parser: *const Parser, text: []const u8) bool {
    for (parser.dialect.comments) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }
    return false;
}

/// `[section]`, or `[A][B]` with nested headers; returns the table its keys go into.
fn header(parser: *Parser, root: *Draft, line: Line) Error!*Draft {
    const text = line.text;
    if (text[text.len - 1] != ']') return parser.fail(line.start, "a [section] header must end with ]", .{});
    if (!parser.dialect.nested_headers) {
        const name = text[1 .. text.len - 1];
        if (name.len == 0) return parser.fail(line.start, "a section name is empty", .{});
        return parser.section(root, name, line.start);
    }
    var table = root;
    var index: usize = 0;
    var depth: usize = 0;
    while (index < text.len) : (depth += 1) {
        if (text[index] != '[') return parser.fail(line.start + index, "unexpected text after a ]: expected another [section] or the end of the line", .{});
        // The line ends with ], so one follows every [.
        const close = std.mem.findScalarPos(u8, text, index + 1, ']') orelse unreachable;
        const name = text[index + 1 .. close];
        if (name.len == 0) return parser.fail(line.start, "a section name is empty", .{});
        if (isKdeFlag(name, depth)) return parser.fail(line.start, "KDE's [{s}] flag is not supported, so kosm never edits a section KDE may lock (D106)", .{name});
        table = try parser.section(table, name, line.start + index);
        index = close + 1;
    }
    return table;
}

/// KDE marks a locked group with `[Group][$i]` and a locked file with `[$i]`; `[$Version]` is
/// an ordinary group.
fn isKdeFlag(name: []const u8, depth: usize) bool {
    if (std.mem.eql(u8, name, "$i")) return true;
    return depth > 0 and name[0] == '$';
}

/// The section `name` inside `parent`, made on first use and shared by every later header.
fn section(parser: *Parser, parent: *Draft, name: []const u8, position: usize) Error!*Draft {
    for (parent.children.items) |child| {
        if (child.kind == .table and std.mem.eql(u8, child.key.?, name)) return child;
    }
    const table = try parser.newDraft(.{ .key = name, .position = position, .kind = .table, .value = null });
    try parent.children.append(parser.allocator, table);
    return table;
}

/// `key = value`; spaces around the `=` and the value are not part of either.
fn pair(parser: *Parser, table: *Draft, line: Line) Error!void {
    const text = line.text;
    const separator = std.mem.findScalar(u8, text, '=') orelse
        return parser.fail(line.start, "expected key = value, a [section] or a comment", .{});
    const key = std.mem.trimEnd(u8, text[0..separator], " \t");
    if (key.len == 0) return parser.fail(line.start, "a key is empty", .{});
    const value = parser.valueRange(line.start + separator + 1, line.start + text.len);
    try table.children.append(parser.allocator, try parser.newDraft(.{ .key = key, .position = line.start, .kind = .scalar, .value = value }));
}

/// The value's bytes from `start` to the line's trimmed `end`: up to an inline comment when the
/// dialect allows one, and inside its quotes when the dialect keeps them (`Strings.bare`).
fn valueRange(parser: *const Parser, start: usize, end: usize) Range {
    var first = start;
    while (first < end and isSpace(parser.source[first])) first += 1;
    var last = end;
    if (parser.dialect.inline_comments) last = parser.commentStart(first, end) orelse end;
    while (last > first and isSpace(parser.source[last - 1])) last -= 1;
    const value = parser.source[first..last];
    if (parser.dialect.strings == .bare and value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
        return .{ .start = first + 1, .end = last - 1 };
    return .{ .start = first, .end = last };
}

/// Where a comment after a space starts in the value at `start`, past its closing quote if
/// it is quoted.
fn commentStart(parser: *const Parser, start: usize, end: usize) ?usize {
    var index = start;
    if (index < end and parser.source[index] == '"') {
        if (std.mem.findScalarPos(u8, parser.source[0..end], index + 1, '"')) |close| index = close + 1;
    }
    while (index < end) : (index += 1) {
        if (!isSpace(parser.source[index])) continue;
        if (parser.isComment(parser.source[index + 1 .. end])) return index;
    }
    return null;
}

fn newDraft(parser: *Parser, draft: Draft) Error!*Draft {
    const result = try parser.allocator.create(Draft);
    result.* = draft;
    return result;
}

fn freeze(parser: *Parser, draft: *const Draft) Error!Node {
    const children = try parser.allocator.alloc(Node, draft.children.items.len);
    for (draft.children.items, children) |child, *node| node.* = try parser.freeze(child);
    return .{ .key = draft.key, .kind = draft.kind, .position = draft.position, .value = draft.value, .children = children };
}

fn fail(parser: *const Parser, position: usize, comptime format: []const u8, arguments: anytype) error{InvalidSyntax} {
    const line = 1 + std.mem.count(u8, parser.source[0..position], "\n");
    return parser.context.invalidSyntax("line {d}: " ++ format, .{line} ++ arguments);
}

const testing = std.testing;

const default_dialect: Dialect = .{ .name = "ini" };

fn parseForTest(arena: *std.heap.ArenaAllocator, source: []const u8, dialect: *const Dialect, context: *kosm.Adapter.Context) Error!Node {
    context.* = .{ .format = kosm.Format.kosm_default };
    return parse(arena.allocator(), source, context, dialect);
}

fn expectFailure(source: []const u8, dialect: *const Dialect, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = undefined;
    try testing.expectError(error.InvalidSyntax, parseForTest(&arena, source, dialect, &context));
    try testing.expectEqualStrings(message, context.message());
}

test "a section spelled twice is one table, and [A][B] nests" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = undefined;
    const root = try parseForTest(&arena,
        \\top=1
        \\[Colors:Header]
        \\A=1
        \\[Colors:Header][Inactive]
        \\B=2
        \\[Colors:Header]
        \\C=3
    , &default_dialect, &context);
    try testing.expectEqual(2, root.children.len);
    const colors = root.children[1];
    try testing.expectEqualStrings("Colors:Header", colors.key.?);
    try testing.expectEqual(null, colors.value);
    try testing.expectEqual(3, colors.children.len);
    try testing.expectEqualStrings("Inactive", colors.children[1].key.?);
    try testing.expectEqualStrings("C", colors.children[2].key.?);
}

test "without nested headers the brackets' whole text is one section" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = undefined;
    const flat: Dialect = .{ .name = "flat", .nested_headers = false };
    const root = try parseForTest(&arena, "[a][b]\nx=1\n", &flat, &context);
    try testing.expectEqualStrings("a][b", root.children[0].key.?);
}

test "values: empty, quoted, starting with #, and inline comments when allowed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = undefined;
    const source = "a=\nb = \"Maple Mono 13\"  \nc=#041C26 # not a comment\r\n";
    const root = try parseForTest(&arena, source, &default_dialect, &context);
    const expected = [_][]const u8{ "", "Maple Mono 13", "#041C26 # not a comment" };
    for (root.children, expected) |child, text| {
        try testing.expectEqualStrings(text, source[child.value.?.start..child.value.?.end]);
    }
    const commented: Dialect = .{ .name = "commented", .inline_comments = true, .strings = .quoted };
    const commented_source = "a = 12 # points\nb = \"x # y\" ; z\nc = #fff\n";
    const commented_root = try parseForTest(&arena, commented_source, &commented, &context);
    const commented_expected = [_][]const u8{ "12", "\"x # y\"", "#fff" };
    for (commented_root.children, commented_expected) |child, text| {
        try testing.expectEqualStrings(text, commented_source[child.value.?.start..child.value.?.end]);
    }
}

test "a file the dialect can't read is an error naming the line" {
    try expectFailure("a=1\njust words\n", &default_dialect, "line 2: expected key = value, a [section] or a comment");
    try expectFailure("[colors\n", &default_dialect, "line 1: a [section] header must end with ]");
    try expectFailure("[a] x\n", &default_dialect, "line 1: a [section] header must end with ]");
    try expectFailure("[a]x[b]\n", &default_dialect, "line 1: unexpected text after a ]: expected another [section] or the end of the line");
    try expectFailure("[]\n", &default_dialect, "line 1: a section name is empty");
    try expectFailure("\n = 1\n", &default_dialect, "line 2: a key is empty");
    try expectFailure("[General][$i]\n", &default_dialect, "line 1: KDE's [$i] flag is not supported, so kosm never edits a section KDE may lock (D106)");
    try expectFailure("[$i]\n", &default_dialect, "line 1: KDE's [$i] flag is not supported, so kosm never edits a section KDE may lock (D106)");
    const sectioned: Dialect = .{ .name = "dunst", .top_level_keys = false };
    try expectFailure("# hi\nfollow = mouse\n", &sectioned, "line 2: a key before the first [section], which dunst files don't allow");
}

test "[$Version] is an ordinary section" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = undefined;
    const root = try parseForTest(&arena, "[$Version]\nupdate_info=x\n", &default_dialect, &context);
    try testing.expectEqualStrings("$Version", root.children[0].key.?);
}
