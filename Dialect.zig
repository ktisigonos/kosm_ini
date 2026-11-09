//! One program's flavour of INI. INI has no standard, so every choice a real config
//! needs is a field with a default that fits most files; `kosm_ini.dialect` turns it into an
//! adapter. How colors, booleans and floats are spelled is not a dialect choice: it is the
//! file's `kosm.Format`, which the app sets.

const Dialect = @This();

const kosm = @import("kosm");

/// The adapter's name, which apps pass as `.lang`: "ini", "foot".
name: []const u8,
/// File extensions the adapter claims, with the dot. Most INI files have none of their own
/// (`kdeglobals`, `dunstrc`), so they are picked with `.lang` instead.
extensions: []const []const u8 = &.{},
/// How this dialect spells values where neither the app nor the user chose.
default_format: kosm.Format = .{ .color = .hex, .boolean = .true_false },
/// Prefixes that start a comment line, after any leading spaces. The first one writes block
/// markers. Default `#` and `;`.
comments: []const []const u8 = &.{ "#", ";" },
/// Whether a comment may follow a value on its line (`size = 12 # points`): a comment prefix
/// after a space then ends the value. Off by default, since values such as `Color=#041C26`
/// start with one.
inline_comments: bool = false,
/// Whether `[A][B]` is section B inside section A, as KDE writes it. Off: the whole text
/// between the outer brackets is one section name. On by default.
nested_headers: bool = true,
/// Whether keys may come before the first section, belonging to the top level (foot). Off makes
/// them an error. On by default.
top_level_keys: bool = true,
/// How strings are written and how quoted values are read. Default `.bare`.
strings: Strings = .bare,
/// What `generate` writes between a key and its value. Reading takes `key=value` and
/// `key = value` alike. Default `" = "`.
separator: []const u8 = " = ",

/// Whether the dialect quotes text.
pub const Strings = enum {
    /// Strings are written as they are. A value the file wraps in `"..."` keeps its quotes, and
    /// an edit replaces only the text between them (dunst's `font = "Maple Mono 13"`).
    bare,
    /// Strings, colors and joined values are written in `"..."`, and a quoted value's quotes
    /// belong to it, so an edit replaces them too.
    quoted,
};
