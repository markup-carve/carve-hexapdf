# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "carve/hexapdf"

class CarveHexapdfTest < Minitest::Test
  def assert_valid_pdf(bytes, min: 800)
    assert_kind_of String, bytes
    assert_equal "%PDF", bytes[0, 4], "output does not start with a PDF header"
    assert_operator bytes.bytesize, :>=, min, "PDF looks too small to hold content"
    # Round-trip through HexaPDF to prove it is structurally loadable.
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    assert_operator doc.pages.count, :>=, 1
    doc.pages.count
  end

  def pdf_content(bytes)
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    doc.pages.map(&:contents).join("\n")
  end

  def test_render_returns_pdf_bytes
    assert_valid_pdf Carve::Hexapdf.render("# Hello *world*")
  end

  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, Carve::Hexapdf::VERSION)
  end

  def test_inline_styles_do_not_raise
    src = "A *bold*, /italic/, _*both*_, `code`, [link](https://x.io), " \
          "~~strike~~, ^sup^ and ,sub, run."
    assert_valid_pdf Carve::Hexapdf.render(src)
  end

  def test_all_common_blocks_render
    src = <<~CRV
      # Heading 1

      ## Heading 2

      A paragraph with a [link](https://carve.example) and `code`.

      - bullet one
      - bullet two
        - nested

      1. first
      2. second

      - [x] done
      - [ ] todo

      |= Col A |= Col B |
      | a1     | b1     |
      | a2     | b2     |

      > A quote.

      ```ruby
      puts "hi"
      ```

      ---

      Done.
    CRV
    assert_valid_pdf Carve::Hexapdf.render(src), min: 1500
  end

  def test_render_ast_accepts_preparsed_tree
    ast = Carve.parse("# From AST")
    assert_valid_pdf Carve::Hexapdf.render_ast(ast)
  end

  def test_render_file_writes_pdf
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.pdf")
      returned = Carve::Hexapdf.render_file("# File output", path)
      assert_equal path, returned
      assert File.file?(path)
      assert_valid_pdf File.binread(path)
    end
  end

  def test_empty_document_still_produces_a_pdf
    assert_valid_pdf Carve::Hexapdf.render(""), min: 400
  end

  def test_unknown_and_dropped_nodes_degrade_gracefully
    # Raw HTML and comments have no PDF form; a heading must still render.
    src = <<~CRV
      # Title

      <div>raw html</div>

      %% a comment

      Body text.
    CRV
    assert_valid_pdf Carve::Hexapdf.render(src)
  end

  def test_custom_fonts_and_page_size
    bytes = Carve::Hexapdf.render("# Custom\n\nBody.", page_size: :Letter,
                                  base_font: "Helvetica", code_font: "Courier")
    assert_valid_pdf bytes
  end

  # A minimal valid 1x1 transparent PNG.
  PNG_1PX = [
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489" \
    "0000000d4944415478da6360000002000001e221bc330000000049454e44ae426082",
  ].pack("H*")

  def test_all_emphasis_decorations_render
    src = "Plain, *bold*, /italic/, _underline_, ~~strike~~, ^super^, ,sub,, " \
          "and ==highlight== together."
    assert_valid_pdf Carve::Hexapdf.render(src)
  end

  def test_table_with_col_and_row_spans_renders
    src = <<~CRV
      |= A |= B |= C |
      | 1  | 2  << |
      | ^  | 4  | 5  |
    CRV
    assert_valid_pdf Carve::Hexapdf.render(src)
  end

  def test_span_counts
    # Row 1 is [^, d, <]: the `^` in column 0 extends "a" downward, and the `<`
    # in column 2 extends "d" rightward.
    rows = Carve.parse("| a | b | c |\n| ^ | d | < |\n")[:children].first[:rows]
    r = Carve::Hexapdf::Renderer.allocate
    resolved = r.send(:resolve_spans, rows)
    # Row 0: a,b,c all 1x1, but "a" gains a row_span from the `^` beneath it.
    assert_equal [1, 1, 1], resolved[0].map { |o| o[:col_span] }
    assert_equal 2, resolved[0][0][:row_span]
    assert_equal [1, 1], resolved[0][1..].map { |o| o[:row_span] }
    # Row 1: only "d" is a real originator; it absorbs the `<` -> col_span 2.
    assert_equal 1, resolved[1].size
    assert_equal 2, resolved[1][0][:col_span]
    assert_equal 1, resolved[1][0][:row_span]
  end

  def test_highlight_color_option_accepted
    # Regression: highlight_color: must be a real, forwarded option.
    assert_valid_pdf Carve::Hexapdf.render("=hi= there", highlight_color: "ffcc00")
    assert_valid_pdf Carve::Hexapdf.render_ast(Carve.parse("=hi="), highlight_color: "ffcc00")
  end

  def test_style_kwargs_are_sugar_and_explicit_styles_win
    bytes = Carve::Hexapdf.render("[link](https://example.com)",
                                  link_color: "00ff00",
                                  styles: { "link" => { fill_color: "ff0000" } })
    assert_valid_pdf bytes
    content = pdf_content(bytes)
    assert_includes content, "1.0 0.0 0.0 rg"
    refute_includes content, "0.0 1.0 0.0 rg"
  end

  def test_heading_and_code_block_styles_are_observable
    src = <<~CRV
      # Styled

      ```
      code
      ```
    CRV
    bytes = Carve::Hexapdf.render(src, styles: {
      "heading" => { fill_color: "ff0000" },
      "code.block" => { box: { background_color: "00ff00" } },
    })
    assert_valid_pdf bytes
    content = pdf_content(bytes)
    assert_includes content, "1.0 0.0 0.0 rg"
    assert_includes content, "0.0 1.0 0.0 rg"
  end

  def test_admonition_kind_style_is_specific
    src = <<~CRV
      ::: warning
      Be careful.
      :::

      ::: note
      Remember this.
      :::
    CRV
    bytes = Carve::Hexapdf.render(src, styles: {
      "admonition.warning" => { box: { background_color: "ff0000" } },
      "admonition.note" => { box: { background_color: "00ff00" } },
    })
    assert_valid_pdf bytes
    content = pdf_content(bytes)
    assert_includes content, "1.0 0.0 0.0 rg"
    assert_includes content, "0.0 1.0 0.0 rg"
  end

  def test_base_font_renders_all_constructs
    src = <<~CRV
      # Head

      Para with *bold*, `code`, [link](https://example.com), =mark=.

      - item
      - [x] task

      > quote

      ::: note
      body
      :::

      :: term
      :  def

      |= h |
      | b |

      ---
    CRV
    assert_valid_pdf Carve::Hexapdf.render(src, styles: { "base" => { font: "Helvetica" } })
    assert_valid_pdf Carve::Hexapdf.render(src, base_font: "Helvetica")
    assert_valid_pdf Carve::Hexapdf.render(src, styles: { "base" => { font_size: 12 } })
  end

  def test_kitchen_sink_styles_on_every_key_render_without_raising
    src = <<~CRV
      # Head

      Para with *bold*, `code`, [link](https://example.com), =mark=, $`x^2`.

      - item
      - [x] task

      > quote

      ::: warning
      body
      :::

      :: term
      :  def

      |= h1 |= h2 |
      | a | b |

      ![alt](missing.png)

      ---
    CRV
    keys = %w[
      base heading heading.1 paragraph code code.block code.inline quote
      admonition admonition.warning list definition_list table table.header
      table.caption figure.caption link highlight image math thematic_break
    ]
    sink = { font: "Helvetica", font_size: 13, fill_color: "112233",
             box: { background_color: "445566", padding: 3 } }
    styles = keys.to_h { |k| [k, sink] }
    assert_valid_pdf Carve::Hexapdf.render(src, styles: styles)
  end

  def test_block_box_styles_do_not_leak_into_inline_runs
    assert_valid_pdf Carve::Hexapdf.render(
      "`code` and =mark= and [l](https://example.com)\n",
      styles: {
        "code" => { box: { background_color: "ff0000" } },
        "highlight" => { box: { padding: 2 } },
        "link" => { box: { padding: 2 } },
      },
    )
  end

  def test_task_list_text_gets_paragraph_styles
    bytes = Carve::Hexapdf.render("- [x] task text\n",
                                  styles: { "paragraph" => { fill_color: "ff0000" } })
    assert_valid_pdf bytes
    assert_includes pdf_content(bytes), "1.0 0.0 0.0 rg"
  end

  def test_task_list_text_uses_base_font
    bytes = Carve::Hexapdf.render("- [x] task text\n", styles: { "base" => { font: "Helvetica" } })
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    fonts = doc.pages.flat_map do |page|
      page.resources[:Font].value.values.map { |ref| doc.deref(ref)[:BaseFont].to_s }
    end
    assert_includes fonts, "Helvetica"
    refute_includes fonts, "Times-Roman"
  end

  def test_bold_link_keeps_variant_with_custom_base_font
    bytes = Carve::Hexapdf.render("*[link](https://example.com)*",
                                  styles: { "base" => { font: "Helvetica" } })
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    fonts = doc.pages.flat_map do |page|
      page.resources[:Font].value.values.map { |ref| doc.deref(ref)[:BaseFont].to_s }
    end
    assert_includes fonts, "Helvetica-Bold"
  end

  def test_base_font_applies_to_plain_text
    bytes = Carve::Hexapdf.render("Just plain text.", styles: { "base" => { font: "Helvetica" } })
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    fonts = doc.pages.flat_map do |page|
      page.resources[:Font].value.values.map { |ref| doc.deref(ref)[:BaseFont].to_s }
    end
    assert_includes fonts, "Helvetica"
    refute_includes fonts, "Times-Roman"
  end

  def test_table_header_text_styles_are_applied
    bytes = Carve::Hexapdf.render("|= H |\n| body |\n", styles: {
      "table.header" => { fill_color: "ff0000" },
    })
    assert_valid_pdf bytes
    assert_includes pdf_content(bytes), "1.0 0.0 0.0 rg"
  end

  def test_heading_font_style_reaches_bold_runs
    bytes = Carve::Hexapdf.render("# Hello", styles: { "heading" => { font: "Helvetica" } })
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    fonts = doc.pages.flat_map do |page|
      page.resources[:Font].value.values.map { |ref| doc.deref(ref)[:BaseFont].to_s }
    end
    assert_includes fonts, "Helvetica-Bold"
    refute_includes fonts, "Times-Bold"
  end

  def test_hyphenated_admonition_kind_renders_without_raising
    src = <<~CRV
      ::: my-note
      Free-form kind.
      :::
    CRV
    assert_valid_pdf Carve::Hexapdf.render(src)
    assert_valid_pdf Carve::Hexapdf.render(
      src, styles: { "admonition.my-note" => { box: { background_color: "ff0000" } } },
    )
  end

  def test_combined_col_and_row_span_not_overcounted
    # Row 0 "A" spans both columns (A + `<`); row 1 has a `^` under each covered
    # column. The downward extension must count once -> row_span 2, not 3.
    rows = Carve.parse("| A | < |\n| ^ | ^ |\n")[:children].first[:rows]
    r = Carve::Hexapdf::Renderer.allocate
    resolved = r.send(:resolve_spans, rows)
    a = resolved[0][0]
    assert_equal 2, a[:col_span]
    assert_equal 2, a[:row_span]
    assert_empty resolved[1] # both cells in row 1 are markers
  end

  def test_math_renderer_callable_used
    called = []
    math = ->(tex, display) { called << [tex, display]; PNG_1PX }
    src = "Inline $`x^2`$ and block:\n\n$$`E = mc^2`$$\n"
    bytes = Carve::Hexapdf.render(src, renderers: { math: math })
    assert_valid_pdf bytes
    refute_empty called, "math renderer was never invoked"
  end

  def test_math_degrades_without_renderer
    assert_valid_pdf Carve::Hexapdf.render("Inline $`x^2`$ math.")
  end

  def test_diagram_fence_renderer_used
    called = false
    mermaid = ->(_src) { called = true; PNG_1PX }
    src = "```mermaid\ngraph TD; A-->B\n```\n"
    assert_valid_pdf Carve::Hexapdf.render(src, renderers: { mermaid: mermaid })
    assert called, "mermaid renderer was never invoked"
  end

  def test_bad_renderer_return_degrades_gracefully
    src = "Inline $`x`$."
    # Returns a non-String -> must fall back to source, not crash.
    assert_valid_pdf Carve::Hexapdf.render(src, renderers: { math: ->(*) { 42 } })
    # Raises -> must be caught.
    assert_valid_pdf Carve::Hexapdf.render(src, renderers: { math: ->(*) { raise "boom" } })
  end

  def test_inline_data_uri_image
    b64 = ["#{[PNG_1PX].pack("m0")}"].first
    src = "Logo ![logo](data:image/png;base64,#{b64}) inline."
    assert_valid_pdf Carve::Hexapdf.render(src)
  end

  def test_definition_list_and_blockquote_attribution
    src = <<~CRV
      Term
      :  Definition of the term.

      > Cited text.
      ^ Author Name
    CRV
    assert_valid_pdf Carve::Hexapdf.render(src)
  end
end
