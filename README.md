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
| `renderers` | `nil` | Callables that turn math / diagram source into image bytes (see below) |

## Supported constructs

Headings, paragraphs, all inline emphasis (strong / emphasis / bold-italic /
**underline** / **strikethrough** / **superscript** / **subscript** /
**highlight**), code, links, autolinks, soft & hard breaks, ordered / unordered
/ task lists (nested), **tables with header rows and full row / column spans**,
block quotes (with attribution), fenced code blocks, divs, admonitions,
definition lists, figures, thematic breaks, critic markup (insert → underline,
delete → strikethrough), footnote references (superscript), and **images** -
both block and inline, embedded from a local file path or a `data:` URI.

### Math and diagrams (renderer callables)

PDF has no client-side renderer, so math and diagram fences are turned into
embedded raster images through callables you supply in `renderers:`. Each
returns image bytes (PNG/JPG); a missing renderer, or one that returns a
non-String or raises, degrades that construct to its monospace source.

```ruby
Carve::Hexapdf.render(source, renderers: {
  # inline `$`x`$` and display `$$`x`$$` math:
  math: ->(tex, display) { my_tex_to_png(tex, display) },   # -> String (image bytes) | nil
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
