# carve-hexapdf

Render the [Carve](https://github.com/markup-carve/carve) markup language to
**PDF** from Ruby, using the pure-Ruby [HexaPDF](https://hexapdf.gettalong.org)
document composition engine.

Carve source is parsed with [`Carve.parse`](https://github.com/markup-carve/carve-rb)
(from the `carve-lang` gem) and the resulting AST is walked onto a
`HexaPDF::Composer`:

- **Inline** nodes become HexaPDF styled text runs: `*strong*` and `/emphasis/`
  map to bold / italic font variants, `` `code` `` to a monospace font, links to
  a colored run with a clickable URI overlay.
- **Block** nodes map to HexaPDF boxes: headings and paragraphs to text boxes,
  lists to list boxes (ordered / unordered / task), tables to table boxes,
  block quotes / divs / admonitions to styled containers, and images to image
  boxes.

## Install

```ruby
# Gemfile
gem "carve-hexapdf"
```

```sh
bundle install
```

`carve-hexapdf` depends on `carve-lang` (a native gem that builds the Carve
engine via Rust) and on `hexapdf`.

## Usage

```ruby
require "carve/hexapdf"

# Carve syntax note: *...* is STRONG (bold), /.../ is EMPHASIS (italic).
pdf_bytes = Carve::Hexapdf.render(<<~CRV)
  # Report

  A paragraph with *bold*, /italic/, `code`, and a [link](https://example.com).

  |= Name |= Score |
  | Ann   | 42     |
  | Bob   | 7      |
CRV

# Write straight to a file:
Carve::Hexapdf.render_file("# Hello", "hello.pdf")

# Render an already-parsed / transformed AST:
ast = Carve.parse("# From AST")
pdf_bytes = Carve::Hexapdf.render_ast(ast)
```

### Options

| Option | Default | Meaning |
| ------ | ------- | ------- |
| `page_size` | `:A4` | HexaPDF page size (e.g. `:A4`, `:Letter`) |
| `margin` | `45` | Page margin in points |
| `base_font` | `"Times"` | Proportional font family |
| `code_font` | `"Courier"` | Monospace font family |
| `link_color` | `"hp-blue"` | Fill color for links |
| `highlight_color` | `"fff3a3"` | Background color for `=highlight=` |
| `styles` | `nil` | Hierarchical style overrides (see below) |
| `renderers` | `nil` | Callables that turn math / diagram source into image bytes (see below) |

## Styling

Pass `styles:` to restyle renderer output without patching the renderer. Keys are
hierarchical dotted names; more specific entries win before parent entries, and
user values win over defaults at the same key.

```ruby
Carve::Hexapdf.render(source, styles: {
  "heading" => { fill_color: "333333" },
  "code.block" => { box: { background_color: "fff8dd", padding: 8 } },
  "admonition.warning" => { box: { background_color: "fff0f0" } },
})
```

Resolution examples:

- `heading.1` resolves through `heading` and then `base`.
- `code.inline` resolves through `code` and then `base`.
- `admonition.warning` resolves through `admonition` and then `base`.
- `box:` hashes deep-merge; other values, including margin arrays, replace as a
  whole.
- `box:` only takes effect on keys that draw a surrounding box (`code.block`,
  `quote`, `admonition`, `definition_list`, `math`); on text-only keys it is
  ignored.
- `list` accepts only its structural properties (`item_spacing`,
  `content_indentation`); item text styling flows through `paragraph`.

Specificity comes first: `"heading" => { font_size: 30 }` does not override the
default `heading.1` size of `22`, but `"heading" => { fill_color: "333333" }`
does apply to all heading levels. To change all heading sizes, set
`heading.1` through `heading.6` individually.

Existing keyword options are sugar under `styles:` and explicit style entries
win: `base_font:` maps to `base.font`, `code_font:` to `code.font`,
`link_color:` to `link.fill_color`, and `highlight_color:` to
`highlight.background_color`.

| Key | Defaults |
| --- | -------- |
| `base` | `{ font: "Times" }` |
| `heading` | `{ margin: [10, 0, 6] }` |
| `heading.1` ... `heading.6` | `{ font_size: 22 }`, `{ font_size: 18 }`, `{ font_size: 15 }`, `{ font_size: 13 }`, `{ font_size: 12 }`, `{ font_size: 11 }` |
| `paragraph` | `{ margin: [0, 0, 8] }` |
| `code` | `{ font: "Courier" }` |
| `code.block` | `{ font_size: 9, margin: [2, 0, 8], box: { background_color: "f2f2f2", padding: 6 } }` |
| `code.inline` | `{}` |
| `quote` | `{ box: { margin: [2, 0, 8], padding: [4, 10], background_color: "f7f7f7" } }` |
| `admonition` | `{ box: { margin: [2, 0, 8], padding: [6, 10], background_color: "eef3fb" }, title_margin: [0, 0, 4] }` |
| `admonition.<kind>` | No defaults; any kind the parser accepts works (including hyphenated ones) |
| `list` | `{ item_spacing: 3, content_indentation: 18 }` |
| `definition_list` | `{ box: { margin: [0, 0, 8] }, definition_indent: 16 }` |
| `table` | `{ font_size: 10, cell_padding: 4, margin: [2, 0, 8] }` |
| `table.header` | `{}` |
| `table.caption` | `{ font_size: 9, margin: [0, 0, 8] }` |
| `figure.caption` | `{ font_size: 9, margin: [2, 0, 8], text_align: :center }` |
| `footnote` | `{ font_size: 9, margin: [0, 0, 3] }` (endnote section entries) |
| `link` | `{ fill_color: "hp-blue" }` |
| `highlight` | `{ background_color: "fff3a3" }` |
| `image` | `{ margin: [2, 0, 8] }` |
| `math` | `{ font_size: 11, margin: [4, 0, 8], box: { padding: 4 } }` |
| `thematic_break` | `{ height: 2, margin: [8, 0, 8], background_color: "cccccc" }` |

## Supported constructs

Headings, paragraphs, all inline emphasis (strong / emphasis / bold-italic /
**underline** / **strikethrough** / **superscript** / **subscript** /
**highlight**), code, links, autolinks, soft & hard breaks, ordered / unordered
/ task lists (nested), **tables with header rows and full row / column spans**,
block quotes (with attribution), fenced code blocks, divs, admonitions,
definition lists, figures, thematic breaks, critic markup (insert → underline,
delete → strikethrough), **footnotes** (superscript `[n]` markers with the
bodies collected into a numbered endnote section - inline `^[..]` and
referenced `[^id]` alike), and **images** - both block and inline, embedded
from a local file path or a `data:` URI. Task-list checkboxes are drawn in the
list marker column, so item text and nested lists align like any other list.

### Math and diagrams (renderer callables)

PDF has no client-side renderer, so math and diagram fences are turned into
embedded raster images through callables you supply in `renderers:`. Each
returns image bytes (PNG/JPG) as a String - or a Hash `{ bytes:, width:,
height: }` (points) to control the drawn size, so high-DPI rasters embed
crisply at their intended dimensions. A missing renderer, or one that returns
anything else or raises, degrades that construct to its monospace source.

```ruby
Carve::Hexapdf.render(source, renderers: {
  # inline `$`x`$` and display `$$`x`$$` math:
  math: ->(tex, display) { my_tex_to_png(tex, display) },   # -> bytes | {bytes:, width:, height:} | nil
  # fenced ```mermaid / ```dot|graphviz / ```chart|vega:
  mermaid:  ->(src) { my_mermaid_to_png(src) },
  graphviz: ->(src) { my_dot_to_png(src) },
  chart:    ->(src) { my_chart_to_png(src) },
})
```

### Graceful degradation

The renderer never raises on an unsupported node - it degrades so a document
always produces a PDF:

- **Math / diagram** fences without a matching `renderers:` callable render
  their source in a monospace run.
- **Remote image URLs** (`http(s)://`) are shown as alt text - no network
  fetching. Local files and `data:` URIs are embedded.
- **Raw HTML** blocks/inlines and **comments** are dropped.

## Licensing

This gem is **MIT** licensed. However, **HexaPDF is dual-licensed AGPL-3.0 /
commercial**. If you distribute software or offer it over a network while
depending on HexaPDF, you must comply with the AGPL (open-source your
application) or hold a
[HexaPDF commercial license](https://hexapdf.gettalong.org/#pricing). This gem
only bridges Carve to HexaPDF; your use of HexaPDF is governed by HexaPDF's own
terms.

## License

MIT, markup-carve. See [LICENSE](LICENSE).
