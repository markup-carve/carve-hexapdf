# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

class OwnerlessTableSpanTest < Minitest::Test
  def test_ownerless_span_markers_keep_drawable_cells
    [
      "| a | b |\n|---|---|\n| < | ^ |\n",
      "| ^ | b |\n|---|---|\n| x | y |\n",
    ].each do |source|
      pdf = Carve::Hexapdf.render(source)

      assert pdf.start_with?("%PDF-")
      assert_equal 1, HexaPDF::Document.new(io: StringIO.new(pdf)).pages.count
    end
  end
end
