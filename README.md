# kosm_ini

INI for kosm (D106). INI has no standard, so `kosm_ini` is a base: `dialect` builds an adapter
for one program's flavour, with every choice a field of `kosm_ini.Dialect` that has a sensible
default. The package exports one adapter, `ini`, with the defaults; it claims `.ini`, and
files without that extension (`kdeglobals`, `dunstrc`, qt5ct's colors) pass `.lang = "ini"`.
Apps use it through `output.edit`, `output.generate` and `output.block`; it knows no app (D1).

A package for a program whose INI differs exports its own dialect:

```zig
pub const adapter = @import("kosm_ini").dialect(.{ .name = "dunst", .strings = .quoted });
```

## Dialect fields

| Field | Default | Meaning |
|---|---|---|
| `name` | required | the adapter's name, passed as `.lang` |
| `extensions` | none | file extensions the adapter claims, with the dot |
| `default_format` | `#rrggbb`, `true`/`false` | how values are spelled unless the app or user chose (D70) |
| `comments` | `#`, `;` | prefixes starting a comment line; the first writes block markers |
| `inline_comments` | `false` | a comment prefix after a space ends a value (`size = 12 # pt`) |
| `nested_headers` | `true` | `[A][B]` is section B inside A, as KDE writes it |
| `top_level_keys` | `true` | keys may come before the first section |
| `strings` | `.bare` | `.bare`: strings written as they are, and a `"..."` value keeps its quotes on edit. `.quoted`: strings, colors and joined values written in quotes, which an edit replaces too |
| `separator` | `" = "` | what `generate` writes between a key and its value |

Colors, booleans and float precision are not dialect fields: they are the file's
`kosm.Format`, which the app sets (foot's `rrggbb`, KDE's `#RRGGBB`, `yes`/`no`).

## Behaviour

- **Paths:** `[section]` names are one segment as written, so `[Colors:Header]` is
  `Colors:Header` and `[Colors:Header][Inactive]` is `Colors:Header.Inactive`; a name holding
  a dot is a quoted segment (D32). Keys are everything before the
  first `=`, spaces around it dropped: `Show Preview`, `Name[$e]`.
- **Spelled twice:** a section spelled twice is one table. A key written twice is two
  matches, so `set` fails and `setAll` or `setNth` choose (D31).
- **Values** run to the end of the line, outer spaces dropped; `Enable=` is an empty value that
  can be set. With the default dialect `Color=#041C26` is a value, not a comment.
- **Refused, writing nothing (G6):** lists (INI has none; build the program's spelling as a
  joined value, D89), text with a line break, and text that would read back differently (outer
  spaces or quotes on a bare string, a quote in a quoted one).
- **KDE's `[$i]` flag** (a locked group, `[General][$i]`) is an error naming the line, so kosm
  never edits a group KDE may lock. `[$Version]` is an ordinary section.
- **Whole files:** `generate` writes top-level keys first, then one `[section]` per table;
  nested tables become `[A][B]` headers.
- **Blocks:** `# kosm:begin <id>` comments. A block's top-level keys belong to the section
  above it, so a block appended after the user's sections should hold only sections.
