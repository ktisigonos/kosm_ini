//! INI (D106): one adapter per `Dialect`, each reading and writing files the way it says.
//! INI has no lists, so a list is refused; a table is a `[section]`, written by `generate`.

const std = @import("std");
const kosm = @import("kosm");
const Dialect = @import("Dialect.zig");
const Parser = @import("Parser.zig");

/// The adapter for `options`: enables `edit`, `generate` and `block` (D71) for its files.
pub fn dialect(comptime options: Dialect) kosm.Adapter {
    if (options.comments.len == 0) @compileError("an INI dialect needs at least one comment prefix, for block markers (D72)");
    const Capabilities = struct {
        const chosen = options;

        fn parse(allocator: std.mem.Allocator, source: []const u8, context: *kosm.Adapter.Context) kosm.Adapter.ParseError!kosm.Adapter.Node {
            return Parser.parse(allocator, source, context, &chosen);
        }

        fn format(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
            return formatValue(writer, value, context, &chosen);
        }

        fn serialize(writer: *std.Io.Writer, root: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
            return serializeFile(writer, root, context, &chosen);
        }
    };
    return .{
        .name = options.name,
        .extensions = options.extensions,
        .default_format = options.default_format,
        .format = Capabilities.format,
        .parser = Capabilities.parse,
        .serialize = Capabilities.serialize,
        .comment = .{ .line = options.comments[0] },
    };
}

/// Longest text value (a joined value, D89) kosm renders before checking it.
const max_text_length = 64 * 1024;

/// Deepest `[A][B]...` header `serialize` writes.
const max_header_depth = 64;

/// The names of the section being written, outermost first.
const HeaderPath = struct {
    names: [max_header_depth][]const u8 = undefined,
    length: usize = 0,
};

fn serializeFile(writer: *std.Io.Writer, root: kosm.Value, context: *kosm.Adapter.Context, options: *const Dialect) kosm.Adapter.Error!void {
    if (root != .table) return context.unsupported("an INI file is a table of keys and sections, not a {s}", .{@tagName(root)});
    var path: HeaderPath = .{};
    var wrote_anything = false;
    try writeSection(writer, root.table, &path, &wrote_anything, context, options);
}

/// A section's own keys first, then the sections inside it.
fn writeSection(writer: *std.Io.Writer, entries: []const kosm.Value.Entry, path: *HeaderPath, wrote_anything: *bool, context: *kosm.Adapter.Context, options: *const Dialect) kosm.Adapter.Error!void {
    for (entries) |entry| {
        if (entry.value == .table) continue;
        if (path.length == 0 and !options.top_level_keys)
            return context.unsupported("key '{s}' is outside any section, which {s} files don't allow", .{ entry.key, options.name });
        try writeKey(writer, entry.key, context, options);
        try writer.writeAll(options.separator);
        try formatValue(writer, entry.value, context, options);
        try writer.writeByte('\n');
        wrote_anything.* = true;
    }
    for (entries) |entry| {
        const section = switch (entry.value) {
            .table => |section| section,
            else => continue,
        };
        if (path.length == max_header_depth) return context.unsupported("sections nest deeper than {d} levels", .{max_header_depth});
        if (path.length == 1 and !options.nested_headers)
            return context.unsupported("section '{s}' is inside section '{s}', but {s} files have no nested sections", .{ entry.key, path.names[0], options.name });
        try checkSectionName(entry.key, context);
        path.names[path.length] = entry.key;
        path.length += 1;
        defer path.length -= 1;
        if (needsHeader(section)) try writeHeader(writer, path, wrote_anything);
        try writeSection(writer, section, path, wrote_anything, context, options);
    }
}

/// A section holding only sections is spelled by their headers, so its own is left out.
fn needsHeader(entries: []const kosm.Value.Entry) bool {
    if (entries.len == 0) return true;
    for (entries) |entry| if (entry.value != .table) return true;
    return false;
}

fn writeHeader(writer: *std.Io.Writer, path: *const HeaderPath, wrote_anything: *bool) std.Io.Writer.Error!void {
    if (wrote_anything.*) try writer.writeByte('\n');
    for (path.names[0..path.length]) |name| try writer.print("[{s}]", .{name});
    try writer.writeByte('\n');
    wrote_anything.* = true;
}

fn checkSectionName(name: []const u8, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    if (name.len == 0) return context.unsupported("a section name is empty", .{});
    if (std.mem.findAny(u8, name, "[]\r\n") != null)
        return context.unsupported("section name '{s}' holds a bracket or a line break, which INI can't spell", .{name});
}

/// A key as it is; one the parser would read differently is refused.
fn writeKey(writer: *std.Io.Writer, key: []const u8, context: *kosm.Adapter.Context, options: *const Dialect) kosm.Adapter.Error!void {
    if (key.len == 0) return context.unsupported("a key is empty", .{});
    if (std.mem.findAny(u8, key, "=\r\n") != null or key[0] == '[' or isSpace(key[0]) or isSpace(key[key.len - 1]) or startsComment(key, options))
        return context.unsupported("key '{s}' would not read back as the same key", .{key});
    try writer.writeAll(key);
}

/// Writes one value; with `parser`, enables `edit` (D42).
fn formatValue(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context, options: *const Dialect) kosm.Adapter.Error!void {
    switch (value) {
        .raw => |text| try writer.writeAll(text),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try context.writeFloat(writer, float),
        .boolean => |boolean| try context.writeBoolean(writer, boolean),
        .string => |text| try writeText(writer, text, context, options),
        .color, .joined => {
            var buffer: [max_text_length]u8 = undefined;
            var rendered: std.Io.Writer = .fixed(&buffer);
            writePlain(&rendered, value, context) catch |err| switch (err) {
                error.WriteFailed => return context.unsupported("the value is longer than {d} bytes", .{max_text_length}),
                error.UnsupportedValue => return error.UnsupportedValue,
            };
            try writeText(writer, rendered.buffered(), context, options);
        },
        .list => return context.unsupported("INI has no lists; build the program's own spelling as a joined value (D89)", .{}),
        .table => return context.unsupported("a table is a [section], which only generate and blocks write", .{}),
    }
}

/// A value's text: parts of a joined value are written back to back (D89).
fn writePlain(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string, .raw => |text| try writer.writeAll(text),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try context.writeFloat(writer, float),
        .boolean => |boolean| try context.writeBoolean(writer, boolean),
        .color => |color| try context.writeColor(writer, color),
        .joined => |parts| for (parts) |part| try writePlain(writer, part, context),
        .list, .table => return context.unsupported("a joined value holds plain values, not a {s}", .{@tagName(value)}),
    }
}

/// Text bare or quoted, as the dialect says; text that would read back differently is refused (G6).
fn writeText(writer: *std.Io.Writer, text: []const u8, context: *kosm.Adapter.Context, options: *const Dialect) kosm.Adapter.Error!void {
    if (std.mem.findAny(u8, text, "\r\n") != null) return context.unsupported("\"{s}\" holds a line break, which ends an INI value", .{text});
    switch (options.strings) {
        .quoted => {
            if (std.mem.findScalar(u8, text, '"') != null) return context.unsupported("\"{s}\" holds a quote, which {s} strings can't escape", .{ text, options.name });
            try writer.print("\"{s}\"", .{text});
        },
        .bare => {
            if (text.len > 0 and (isSpace(text[0]) or isSpace(text[text.len - 1])))
                return context.unsupported("\"{s}\" starts or ends with a space, which a bare INI value drops", .{text});
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"')
                return context.unsupported("\"{s}\" is wrapped in quotes, which {s} reads as quoting", .{ text, options.name });
            if (options.inline_comments and hasInlineComment(text, options))
                return context.unsupported("\"{s}\" holds a comment prefix after a space, which {s} reads as a comment", .{ text, options.name });
            try writer.writeAll(text);
        },
    }
}

fn hasInlineComment(text: []const u8, options: *const Dialect) bool {
    for (text, 0..) |byte, index| {
        if (isSpace(byte) and startsComment(text[index + 1 ..], options)) return true;
    }
    return false;
}

fn startsComment(text: []const u8, options: *const Dialect) bool {
    for (options.comments) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }
    return false;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

const testing = std.testing;

const plain = dialect(.{ .name = "ini", .extensions = &.{".ini"} });
const quoting = dialect(.{ .name = "dunst", .strings = .quoted, .inline_comments = true, .top_level_keys = false });
const flat = dialect(.{ .name = "flat", .nested_headers = false, .separator = "=" });

fn formatForTest(adapter: kosm.Adapter, value: kosm.Value, output: *std.Io.Writer.Allocating, context: *kosm.Adapter.Context) !void {
    context.* = .{ .format = adapter.default_format.resolve() };
    try adapter.format.?(&output.writer, value, context);
}

test "values are written bare or quoted, as the dialect says" {
    const color = try kosm.Color.parseHex("#041c26");
    const cases = [_]struct { kosm.Adapter, kosm.Value, []const u8 }{
        .{ plain, .{ .string = "Maple Mono NFP:size=13" }, "Maple Mono NFP:size=13" },
        .{ plain, .{ .string = "" }, "" },
        .{ plain, .{ .integer = -42 }, "-42" },
        .{ plain, .{ .float = 13 }, "13" },
        .{ plain, .{ .float = 0.65 }, "0.65" },
        .{ plain, .{ .boolean = false }, "false" },
        .{ plain, .{ .color = color }, "#041c26" },
        .{ plain, .{ .joined = &.{ .{ .integer = 10 }, .{ .raw = "x" }, .{ .integer = 10 } } }, "10x10" },
        .{ plain, .{ .raw = "(0, 500)" }, "(0, 500)" },
        .{ quoting, .{ .string = "Maple Mono 13" }, "\"Maple Mono 13\"" },
        .{ quoting, .{ .color = color }, "\"#041c26\"" },
        .{ quoting, .{ .integer = 10 }, "10" },
        .{ quoting, .{ .boolean = true }, "true" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var context: kosm.Adapter.Context = undefined;
        try formatForTest(case[0], case[1], &output, &context);
        try testing.expectEqualStrings(case[2], output.written());
    }
}

test "values that would read back differently are refused" {
    const cases = [_]struct { kosm.Adapter, kosm.Value, []const u8 }{
        .{ plain, .{ .string = "two\nlines" }, "\"two\nlines\" holds a line break, which ends an INI value" },
        .{ plain, .{ .string = " padded" }, "\" padded\" starts or ends with a space, which a bare INI value drops" },
        .{ plain, .{ .string = "\"quoted\"" }, "\"\"quoted\"\" is wrapped in quotes, which ini reads as quoting" },
        .{ plain, .{ .list = &.{.{ .integer = 1 }} }, "INI has no lists; build the program's own spelling as a joined value (D89)" },
        .{ plain, .{ .table = &.{} }, "a table is a [section], which only generate and blocks write" },
        .{ quoting, .{ .string = "say \"hi\"" }, "\"say \"hi\"\" holds a quote, which dunst strings can't escape" },
        .{ dialect(.{ .name = "commented", .inline_comments = true }), .{ .string = "a ; b" }, "\"a ; b\" holds a comment prefix after a space, which commented reads as a comment" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var context: kosm.Adapter.Context = undefined;
        try testing.expectError(error.UnsupportedValue, formatForTest(case[0], case[1], &output, &context));
        try testing.expectEqualStrings(case[2], context.message());
    }
}

fn serializeForTest(adapter: kosm.Adapter, root: kosm.Value, output: *std.Io.Writer.Allocating, context: *kosm.Adapter.Context) !void {
    context.* = .{ .format = adapter.default_format.resolve() };
    try adapter.serialize.?(&output.writer, root, context);
}

const generated_value: kosm.Value = .{ .table = &.{
    .{ .key = "Colors:Header", .value = .{ .table = &.{
        .{ .key = "BackgroundNormal", .value = .{ .string = "#041C26" } },
        .{ .key = "Inactive", .value = .{ .table = &.{
            .{ .key = "BackgroundNormal", .value = .{ .string = "#082E3F" } },
        } } },
    } } },
    .{ .key = "font", .value = .{ .string = "Maple Mono NFP:size=13" } },
    .{ .key = "WM", .value = .{ .table = &.{
        .{ .key = "Only", .value = .{ .table = &.{
            .{ .key = "x", .value = .{ .integer = 1 } },
        } } },
    } } },
    .{ .key = "empty", .value = .{ .table = &.{} } },
} };

test "a file is written with its top-level keys first, then [sections]" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = undefined;
    try serializeForTest(plain, generated_value, &output, &context);
    try testing.expectEqualStrings(
        \\font = Maple Mono NFP:size=13
        \\
        \\[Colors:Header]
        \\BackgroundNormal = #041C26
        \\
        \\[Colors:Header][Inactive]
        \\BackgroundNormal = #082E3F
        \\
        \\[WM][Only]
        \\x = 1
        \\
        \\[empty]
        \\
    , output.written());
}

test "a written file parses back to the same keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = undefined;
    try serializeForTest(plain, generated_value, &output, &context);
    const root = try plain.parser.?(arena.allocator(), output.written(), &context);
    try expectSameKeys(generated_value, root);
}

fn expectSameKeys(value: kosm.Value, node: kosm.Adapter.Node) !void {
    switch (value) {
        .table => |entries| {
            try testing.expectEqual(.table, node.kind);
            try testing.expectEqual(entries.len, node.children.len);
            for (entries) |entry| {
                const found = for (node.children) |entry_node| {
                    if (std.mem.eql(u8, entry_node.key.?, entry.key)) break entry_node;
                } else return error.TestExpectedEqual;
                try expectSameKeys(entry.value, found);
            }
        },
        else => try testing.expectEqual(.scalar, node.kind),
    }
}

test "a file a dialect can't spell is refused" {
    const cases = [_]struct { kosm.Adapter, kosm.Value, []const u8 }{
        .{ flat, generated_value, "section 'Inactive' is inside section 'Colors:Header', but flat files have no nested sections" },
        .{ quoting, generated_value, "key 'font' is outside any section, which dunst files don't allow" },
        .{ plain, .{ .list = &.{} }, "an INI file is a table of keys and sections, not a list" },
        .{ plain, .{ .table = &.{.{ .key = "a]b", .value = .{ .table = &.{} } }} }, "section name 'a]b' holds a bracket or a line break, which INI can't spell" },
        .{ plain, .{ .table = &.{.{ .key = "a=b", .value = .{ .integer = 1 } }} }, "key 'a=b' would not read back as the same key" },
        .{ plain, .{ .table = &.{.{ .key = "# a", .value = .{ .integer = 1 } }} }, "key '# a' would not read back as the same key" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var context: kosm.Adapter.Context = undefined;
        try testing.expectError(error.UnsupportedValue, serializeForTest(case[0], case[1], &output, &context));
        try testing.expectEqualStrings(case[2], context.message());
    }
}

test "a dialect's separator is used when writing a whole file" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = undefined;
    try serializeForTest(flat, .{ .table = &.{.{ .key = "General", .value = .{ .table = &.{.{ .key = "a", .value = .{ .integer = 1 } }} } }} }, &output, &context);
    try testing.expectEqualStrings("[General]\na=1\n", output.written());
}

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    plan: kosm.Plan,
    diagnostics: kosm.Diagnostics = .{},
    warnings: kosm.Warnings = undefined,
    home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    output: kosm.Output = undefined,

    fn init(fixture: *Fixture, path: []const u8, contents: []const u8) !void {
        fixture.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .plan = .init(testing.allocator, testing.io) };
        if (std.Io.Dir.path.dirname(path)) |parent| try fixture.tmp.dir.createDirPath(testing.io, parent);
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = contents });
        fixture.warnings = .init(fixture.arena.allocator());
        const length = try fixture.tmp.dir.realPath(testing.io, &fixture.home_buffer);
        fixture.output = .{
            .allocator = fixture.arena.allocator(),
            .home = fixture.home_buffer[0..length],
            .adapters = &.{ plain, quoting },
            .plan = &fixture.plan,
            .diagnostics = &fixture.diagnostics,
            .warnings = &fixture.warnings,
            .app = "test",
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.plan.deinit();
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }

    fn written(fixture: *const Fixture) []const u8 {
        return fixture.plan.files.items[0].new;
    }
};

const kdeglobals =
    \\[$Version]
    \\update_info=filepicker.upd:filepicker-remove-old-previews-entry,fonts_global.upd:Fonts_Global
    \\
    \\[ColorEffects:Disabled]
    \\ChangeSelectionColor=
    \\Color=#041C26
    \\ContrastAmount=0.65
    \\
    \\[Colors:Header]
    \\BackgroundNormal=#041C26
    \\ForegroundNormal=#eceff4
    \\
    \\[Colors:Header][Inactive]
    \\BackgroundNormal=#082E3F
    \\ForegroundNormal=#d8dee9
    \\
    \\[Colors:View]
    \\BackgroundNormal=#041C26
    \\
    \\[KFileDialog Settings]
    \\Show Preview=false
    \\Name[$e]=$HOME/x
    \\
;

test "kdeglobals: sections with colons and spaces, [A][B] and empty values are set in place" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/kdeglobals", kdeglobals);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/kdeglobals", .lang = "ini" });
    const background = kosm.hex("102840");
    try file.set("Colors:Header.BackgroundNormal", background.format("#{}", &.{.hex_upper}));
    try file.set("\"Colors:Header\".Inactive.ForegroundNormal", kosm.hex("ffffff"));
    try file.set("\"ColorEffects:Disabled\".ChangeSelectionColor", true);
    try file.set("\"ColorEffects:Disabled\".ContrastAmount", 0.5);
    try file.set("KFileDialog Settings.Show Preview", true);
    try file.set("KFileDialog Settings.Name[$e]", "$HOME/y");
    try testing.expectError(error.TooManyMatches, file.set("*.BackgroundNormal", background));
    try testing.expectError(error.NoMatch, file.set("Colors:Header.BackgroundAlternate", background));
    try testing.expectError(error.NoValue, file.set("\"Colors:Header\".Inactive", 1));
    try file.setNth("*.BackgroundNormal", 1, background);
    try testing.expectEqualStrings(
        \\[$Version]
        \\update_info=filepicker.upd:filepicker-remove-old-previews-entry,fonts_global.upd:Fonts_Global
        \\
        \\[ColorEffects:Disabled]
        \\ChangeSelectionColor=true
        \\Color=#041C26
        \\ContrastAmount=0.5
        \\
        \\[Colors:Header]
        \\BackgroundNormal=#102840
        \\ForegroundNormal=#eceff4
        \\
        \\[Colors:Header][Inactive]
        \\BackgroundNormal=#082E3F
        \\ForegroundNormal=#ffffff
        \\
        \\[Colors:View]
        \\BackgroundNormal=#102840
        \\
        \\[KFileDialog Settings]
        \\Show Preview=true
        \\Name[$e]=$HOME/y
        \\
    , fixture.written());
}

const foot_ini =
    \\font=Maple Mono Normal NFP:size=13
    \\pad=10x10
    \\
    \\[cursor]
    \\style=beam
    \\
    \\[colors]
    \\alpha = 1.0
    \\background=041C26
    \\cursor=041C26 A3C5CC
    \\
    \\regular0 = 041C26
    \\regular1 = 80333C
    \\
    \\bright0 = 082E3F
    \\
;

test "foot.ini: top-level keys, values with and without spaces around =" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/foot/foot.ini", foot_ini);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/foot/foot.ini" });
    const black = kosm.hex("102840");
    try file.set("font", "Iosevka:size=12");
    try file.set("pad", kosm.Value{ .joined = &.{ .{ .integer = 12 }, .{ .raw = "x" }, .{ .integer = 12 } } });
    try file.set("colors.alpha", 0.5);
    try file.set("colors.background", black.format("{}", &.{.hex}));
    try file.set("colors.cursor", "102840 a3c5cc");
    try file.set("colors.regular0", black.format("{}", &.{.hex_upper}));
    try testing.expectEqualStrings(
        \\font=Iosevka:size=12
        \\pad=12x12
        \\
        \\[cursor]
        \\style=beam
        \\
        \\[colors]
        \\alpha = 0.5
        \\background=102840
        \\cursor=102840 a3c5cc
        \\
        \\regular0 = 102840
        \\regular1 = 80333C
        \\
        \\bright0 = 082E3F
        \\
    , fixture.written());
}

const dunstrc =
    \\[global]
    \\    follow = mouse
    \\    width = (0, 500)
    \\    # Font and colors
    \\    font = "Maple Mono Normal NFP 13"
    \\    frame_color = "#2D8699FF"
    \\
    \\[urgency_low]
    \\    background = "#041C2680"
    \\    timeout = 10
    \\
    \\[urgency_normal]
    \\    background = "#041C2680"
    \\    timeout = 10
    \\
    \\[global]
    \\    corner_radius = 10
    \\
;

test "dunstrc with bare strings: quotes are kept, and a section spelled twice is one" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/dunst/dunstrc", dunstrc);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/dunst/dunstrc", .lang = "ini" });
    try file.set("global.font", "Iosevka 12");
    try file.set("global.frame_color", kosm.hex("2d8699").format("#{}FF", &.{.hex_upper}));
    try file.set("global.corner_radius", 8);
    try file.set("global.width", kosm.raw("(0, 400)"));
    try file.setAll("*.timeout", 5);
    try testing.expectEqualStrings(
        \\[global]
        \\    follow = mouse
        \\    width = (0, 400)
        \\    # Font and colors
        \\    font = "Iosevka 12"
        \\    frame_color = "#2D8699FF"
        \\
        \\[urgency_low]
        \\    background = "#041C2680"
        \\    timeout = 5
        \\
        \\[urgency_normal]
        \\    background = "#041C2680"
        \\    timeout = 5
        \\
        \\[global]
        \\    corner_radius = 8
        \\
    , fixture.written());
}

test "dunstrc with quoted strings: an edit replaces the quotes too" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/dunst/dunstrc", dunstrc);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/dunst/dunstrc", .lang = "dunst" });
    try file.set("global.font", "Iosevka 12");
    try file.set("urgency_low.background", kosm.hex("10284080"));
    try file.set("urgency_low.timeout", 3);
    const text = fixture.written();
    try testing.expect(std.mem.indexOf(u8, text, "font = \"Iosevka 12\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[urgency_low]\n    background = \"#102840\"\n    timeout = 3\n") != null);
}

const qt5ct_colors =
    \\# Qt5ct colors: FG  BTN_BG  bright
    \\[ColorScheme]
    \\  active_colors=#ffeceff4, #ff434c5e, #ff4c566a
    \\disabled_colors=#ffd8dee9, #ff2e3440, #ff4c566a
    \\inactive_colors=#ffe5e9f0, #ff3b4252, #ff4c566a
    \\
;

test "qt5ct colors: a list the app joins replaces the whole value" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/qt5ct/colors/kosm.conf", qt5ct_colors);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/qt5ct/colors/kosm.conf", .lang = "ini" });
    try file.set("ColorScheme.active_colors", kosm.Value{ .joined = &.{
        .{ .color = kosm.hex("a3c5cc") }, .{ .raw = ", " }, .{ .color = kosm.hex("041c26") },
    } });
    try testing.expectError(error.UnsupportedValue, file.set("ColorScheme.disabled_colors", [_][]const u8{ "#ff000000", "#ffffffff" }));
    try testing.expectEqualStrings(
        \\# Qt5ct colors: FG  BTN_BG  bright
        \\[ColorScheme]
        \\  active_colors=#a3c5cc, #041c26
        \\disabled_colors=#ffd8dee9, #ff2e3440, #ff4c566a
        \\inactive_colors=#ffe5e9f0, #ff3b4252, #ff4c566a
        \\
    , fixture.written());
}

test "a key written twice is two matches" {
    var fixture: Fixture = undefined;
    try fixture.init("app.ini", "[main]\ninclude=a.ini\ninclude=b.ini\n");
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/app.ini" });
    try testing.expectError(error.TooManyMatches, file.set("main.include", "c.ini"));
    try file.setNth("main.include", 1, "c.ini");
    try testing.expectEqualStrings("[main]\ninclude=a.ini\ninclude=c.ini\n", fixture.written());
}

test "an unchanged value leaves the file unwritten" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/foot/foot.ini", foot_ini);
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/.config/foot/foot.ini" });
    try file.set("colors.regular1", kosm.hex("80333c").format("{}", &.{.hex_upper}));
    try testing.expect(!fixture.plan.hasChanges());
}

test "a file the dialect can't read is an error naming the file and line" {
    var fixture: Fixture = undefined;
    try fixture.init("bad.ini", "[General][$i]\nx=1\n");
    defer fixture.deinit();
    try testing.expectError(error.InvalidSyntax, fixture.output.edit(.{ .files = "~/bad.ini" }));
    try testing.expect(std.mem.indexOf(u8, fixture.diagnostics.message(), "line 1: KDE's [$i] flag is not supported") != null);
}

test "a block of values keeps the user's own lines around it" {
    var fixture: Fixture = undefined;
    try fixture.init(".config/foot/foot.ini", "font=Iosevka\n");
    defer fixture.deinit();
    try fixture.output.block(.{ .file = "~/.config/foot/foot.ini", .id = "colors" }, kosm.Value{ .table = &.{
        .{ .key = "colors", .value = .{ .table = &.{
            .{ .key = "background", .value = .{ .color = try kosm.Color.parseHex("#041c26") } },
        } } },
    } });
    try testing.expectEqualStrings(
        \\font=Iosevka
        \\# kosm:begin colors
        \\[colors]
        \\background = #041c26
        \\# kosm:end
        \\
    , fixture.written());
}
