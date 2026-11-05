# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# Cell alignment, measured as the x offset each string is drawn at.
class TableAlignmentTest < Minitest::Test
  class Positions < HexaPDF::Content::Processor
    attr_reader :x

    def initialize
      super
      @x = {}
    end

    def show_text(str)
      boxes = decode_text_with_positioning(str)
      @x[boxes.string] ||= boxes.lower_left.first
    end
    alias show_text_with_positioning show_text
  end

  def x_of(pdf)
    processor = Positions.new
    HexaPDF::Document.new(io: StringIO.new(pdf)).pages[0].process_contents(processor)
    processor.x
  end

  def render(source)
    x_of(Carve::Hexapdf.render(source))
  end

  def test_unaligned_cells_stay_left
    x = render("|= Long header text |\n| 5 |\n")

    assert_in_delta x["Long header text"], x["5"], 1
  end

  def test_header_alignment_applies_to_its_column
    left = render("|= Long header text |\n| 5 |\n")
    right = render("|=> Long header text |\n| 5 |\n")
    center = render("|=~ Long header text |\n| 5 |\n")

    assert_operator right["5"], :>, center["5"]
    assert_operator center["5"], :>, left["5"]
    assert_operator right["Long header text"], :>, left["Long header text"]
  end

  def test_body_cell_alignment_stays_local
    x = render("|= Long header text |\n|> 5 |\n| 6 |\n")

    assert_operator x["5"], :>, x["6"]
    assert_in_delta x["Long header text"], x["6"], 1
  end

  def test_only_leading_header_rows_set_the_column
    x = render("| 1 |\n|=> Long header text |\n| 6 |\n")

    assert_in_delta x["1"], x["6"], 1
  end

  def test_columns_metadata_aligns_cells_without_their_own
    cell = ->(text, **extra) { { type: "table_cell", header: false, children: [{ type: "text", value: text }], **extra } }
    ast = {
      type: "doc",
      children: [{
        type: "table",
        columns: [{ align: "right" }],
        rows: [
          { type: "table_row", cells: [cell.("Long body text")] },
          { type: "table_row", cells: [cell.("5")] },
          { type: "table_row", cells: [cell.("6", align: "left")] },
        ],
      }],
    }
    x = x_of(Carve::Hexapdf.render_ast(ast))

    assert_operator x["5"], :>, x["6"]
  end
end
