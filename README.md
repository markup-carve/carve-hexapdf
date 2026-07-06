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

## Supported constructs

Headings, paragraphs, inline strong/emphasis/bold-italic/code/links/autolinks,
soft & hard breaks, ordered / unordered / task lists (nested), tables (with
header rows), block quotes (with attribution), fenced code blocks, divs,
admonitions, definition lists, figures, thematic breaks, and images (embedded
when the `src` is a local file, otherwise shown as alt text).

### Graceful degradation

The renderer never raises on an unsupported node - it degrades to the node's
text or children so a document always produces a PDF:

- **Math** and **diagram** fences render their source in a monospace run (PDF
  has no client-side renderer). A future release may accept image-producing
  renderer callables.
- **Table cell spans** (`rowspan` / `colspan`) render as individual cells.
- **Underline / strike / super / sub / highlight** emphasis keeps the text but
  not the decoration (standard PDF fonts limit what is expressible cheaply).
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
