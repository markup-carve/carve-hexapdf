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
