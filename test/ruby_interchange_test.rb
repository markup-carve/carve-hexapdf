# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

class RubyInterchangeTest < Minitest::Test
  def test_ruby_pairs_reach_the_pdf_in_order
    ast = {
      type: "document",
      children: [{
        type: "paragraph",
        children: [{
          type: "ruby",
          pairs: [
            {
              base: [{ type: "strong", children: [{ type: "text", value: "base" }] }],
              annotation: [{ type: "text", value: "note" }]
            },
            {
              base: [{ type: "text", value: "next" }],
              annotation: []
            }
          ]
        }]
      }]
    }

    document = HexaPDF::Document.new(io: StringIO.new(Carve::Hexapdf.render_ast(ast)))
    text = +""
    document.pages.each do |page|
      HexaPDF::Content::Parser.parse(page.contents) do |operator, operands|
        text << operands.flatten.grep(String).join if %i[Tj TJ].include?(operator)
      end
    end

    assert_equal "base(note)next()", text
  end
end
