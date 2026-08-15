# frozen_string_literal: true

require "stringio"
require "base64"

require_relative "style_map"

module Carve
  module Hexapdf
    # Walks a Carve AST (as produced by +Carve.parse+) and draws it onto a
    # HexaPDF::Composer, producing a laid-out PDF document.
    #
    # Block nodes become HexaPDF boxes (text, list, table, container, image);
    # inline nodes become the multi-part styled "runs" that
    # HexaPDF::Composer#formatted_text consumes. Emphasis maps to font variants
    # and text decorations, inline code to a monospace font, links to a colored
    # run with a URI overlay.
    #
    # Math and diagram fences are rendered through optional +renderers:+
    # callables (which return image bytes); without a matching renderer they
    # degrade to their monospace source. The renderer never raises on an
    # unknown or unsupported node - it degrades to text/children so a document
    # always renders.
    class Renderer
      BLOCK_GAP = 8

      # Style properties this renderer consumes itself. They are not HexaPDF
      # style properties, and the style chain hands each of them down to its
      # nested keys: `table.caption` inherits `table`'s :cell_padding,
      # `figure.group.caption` inherits `figure.group`'s column properties.
      # Splatting one into a text box raises NoMethodError, which loses the
      # whole document, so a style destined for a text box drops them
      # (+text_style+). :box is dropped by +style_for+ already.
      RENDERER_PROPS = %i[
        cell_padding column_gap min_column_width title_margin
        definition_indent item_spacing content_indentation
      ].freeze

      # Code-fence languages that map to a diagram renderer key.
      DIAGRAM_LANGS = {
        "mermaid" => :mermaid,
        "dot" => :graphviz,
        "graphviz" => :graphviz,
        "chart" => :chart,
        "vega" => :chart,
      }.freeze

      # @param renderers [Hash] optional callables that turn a construct's
      #   source into raster image bytes (PNG/JPG). Keys:
      #   +:math+ -> callable(tex_string, display_bool);
      #   +:mermaid+/+:graphviz+/+:chart+ -> callable(source_string).
      #   Each callable returns the image bytes as a String, or a Hash with
      #   +:bytes+ and optional +:width+/+:height+ (points) to control the
      #   drawn size of high-DPI rasters. Any other return, or a missing key,
      #   degrades the construct to its source.
      def initialize(composer, base_font: nil, code_font: nil,
                     link_color: nil, highlight_color: nil, styles: nil, renderers: nil)
        @c = composer
        @layout = composer.document.layout
        @styles = StyleMap.new(style_sugar(base_font: base_font, code_font: code_font,
                                           link_color: link_color,
                                           highlight_color: highlight_color,
                                           styles: styles))
        @renderers = renderers || {}
      end

      def render_document(doc)
        # Keys arrive as Symbols (symbolized JSON) while node :id is a String.
        @footnote_defs = collect_footnote_defs(doc)
        @footnotes = []
        @footnote_numbers = {}
        Array(doc[:children]).each { |node| block(node, @c) }
        render_footnotes(@c)
        @c
      end

      # ---- block dispatch ------------------------------------------------

      def block(node, target)
        case node[:type]
        # A definition is RELOCATED, not rendered in place - it belongs in the
        # endnote section, which is what the HTML renderer does with it too.
        # Handled HERE rather than by filtering the root's children, because a
        # definition written inside a container stays inside it (the engines
        # differ on hoisting), and a root-level filter would render that one on
        # the page and again in the endnotes.
        when "footnote"         then nil
        when "heading"          then heading(node, target)
        when "paragraph"        then paragraph(node, target)
        when "code_block"       then code_block(node, target)
        when "list"             then list(node, target)
        when "block_quote"      then block_quote(node, target)
        when "table"            then table(node, target)
        when "thematic_break"   then thematic_break(target)
        when "div"              then container_of(node[:children], target)
        when "admonition"       then admonition(node, target)
        when "definition_list"  then definition_list(node, target)
        when "figure"           then figure(node, target)
        when "figure_group"     then figure_group(node, target)
        when "block_image", "image" then image_block(node, target)
        when "block_extension"  then container_of(node[:children], target)
        when "raw_block", "comment", "abbreviation_def"
          # No meaningful PDF form - drop.
        else
          if inline_children?(node[:children])
            emit_paragraph(node[:children], target)
          elsif node[:children]
            Array(node[:children]).each { |ch| block(ch, target) }
          end
        end
      end

      private

      def style_sugar(base_font:, code_font:, link_color:, highlight_color:, styles:)
        sugar = {}
        sugar["base"] = { font: base_font } unless base_font.nil?
        sugar["code"] = { font: code_font } unless code_font.nil?
        sugar["link"] = { fill_color: link_color } unless link_color.nil?
        sugar["highlight"] = { background_color: highlight_color } unless highlight_color.nil?
        return sugar if styles.nil?
        unless styles.respond_to?(:each_pair)
          raise ArgumentError, "styles must be a Hash-like object"
        end

        styles.each_pair.with_object(sugar) do |(key, value), out|
          key = key.to_s
          out[key] = (out[key] || {}).merge(value)
        end
      end

      # The default base font ("Times") matches HexaPDF's own default, so it is
      # stripped from block styles to keep default output identical to what the
      # composer would produce anyway; a USER-set font at any chain level
      # (including base) must survive into the block style.
      #
      # :box is a pseudo-property consumed only by sites that draw a surrounding
      # box (code blocks, quotes, admonitions, ...); everywhere else it would
      # crash HexaPDF's style handling, so it is stripped unless requested.
      def style_for(key, inherited_font: false, with_box: false)
        style = @styles.resolve(key).dup
        style.delete(:font) unless inherited_font || @styles.user_set_in_chain?(key, :font)
        style.delete(:box) unless with_box
        style
      end

      # A resolved style safe to splat into a HexaPDF text box: the renderer's
      # own properties are dropped, whether they were set on this key or
      # inherited from an ancestor of it (see RENDERER_PROPS).
      def text_style(key, inherited_font: false)
        style_for(key, inherited_font: inherited_font)
          .reject { |prop, _| RENDERER_PROPS.include?(prop) }
      end

      def heading(node, target)
        style = style_for("heading.#{node[:level]}")
        runs = inline_runs(node[:children], bold: true, font_family: style[:font])
        return if runs.empty?

        target.formatted_text(runs, **style)
      end

      def paragraph(node, target)
        # A paragraph that is only a display-math node becomes a centered image.
        children = Array(node[:children])
        if children.size == 1 && children.first[:type] == "math" && children.first[:display]
          return display_math(children.first, target)
        end

        emit_paragraph(children, target)
      end

      def emit_paragraph(children, target, **style)
        merged = style_for("paragraph").merge(style)
        runs = inline_runs(children, font_family: merged[:font])
        return if runs.empty?

        target.formatted_text(runs, **merged)
      end

      def code_block(node, target)
        lang = node[:lang].to_s.downcase
        if (key = DIAGRAM_LANGS[lang]) && (bytes = call_renderer(key, node[:content].to_s))
          return image_bytes(bytes, target)
        end

        content = resolve_nbsp(node[:content]).chomp
        style = style_for("code.block", inherited_font: true, with_box: true)
        box = style.delete(:box)
        target.text(content, **style, box_style: box)
      end

      def list(node, target)
        # The list box is structural: item text styling flows through the
        # paragraph chain, and Composer#list rejects text keywords (:font,
        # :font_size, ...) that the chain inherits from base - whitelist.
        style = style_for("list").slice(:item_spacing, :content_indentation)
        items = Array(node[:items])
        ordered = node[:ordered]
        task = items.any? { |it| !it[:checked].nil? }
        start = node[:start] || 1
        marker = if task
                   # Standard PDF fonts have no checkbox glyphs; draw an ASCII
                   # checkbox in the marker column so item text (and nested
                   # lists) align like any other list.
                   checked = items.map { |it| it[:checked] }
                   font = style_for("paragraph", inherited_font: true)[:font] || "Times"
                   ->(doc, list_box, index) do
                     # A list split across pages continues in a box whose
                     # start_number is advanced by the items already drawn;
                     # index alone is relative to that split remainder.
                     absolute = list_box.start_number - start + index
                     doc.layout.text_box(checked[absolute] ? "[x]" : "[ ]",
                                         font: font, font_size: 10)
                   end
                 elsif ordered
                   :decimal
                 else
                   :disc
                 end

        target.list(**style, marker_type: marker, start_number: start) do |list_box|
          items.each do |item|
            list_box.container do |cell|
              Array(item[:children]).each { |ch| block(ch, cell) }
            end
          end
        end
      end

      def block_quote(node, target)
        target.container(style: style_for("quote", with_box: true)[:box]) do |cont|
          Array(node[:children]).each { |ch| block(ch, cont) }
          if node[:attribution]
            emit_paragraph(node[:attribution], cont, margin: [2, 0, 0])
          end
        end
      end

      def container_of(children, target)
        target.container(style: { margin: [0, 0, BLOCK_GAP] }) do |cont|
          Array(children).each { |ch| block(ch, cont) }
        end
      end

      def admonition(node, target)
        kind = node[:kind].to_s
        key = kind.empty? || kind.include?(".") ? "admonition" : "admonition.#{kind}"
        style = style_for(key, with_box: true)
        target.container(style: style[:box]) do |cont|
          title = node[:title] && !node[:title].empty? ? node[:title] : [{ type: "text", value: node[:kind].to_s.capitalize }]
          cont.formatted_text(inline_runs(title, bold: true, font_family: style[:font]),
                              margin: style[:title_margin])
          Array(node[:children]).each { |ch| block(ch, cont) }
        end
      end

      def definition_list(node, target)
        style = style_for("definition_list", with_box: true)
        target.container(style: style[:box]) do |cont|
          Array(node[:items]).each do |item|
            Array(item[:terms]).each do |term|
              cont.formatted_text(inline_runs(term, bold: true), margin: [2, 0, 1])
            end
            Array(item[:definitions]).each do |defn|
              cont.container(style: { padding: [0, 0, 0, style[:definition_indent]] }) do |dcont|
                Array(defn).each { |ch| block(ch, dcont) }
              end
            end
          end
        end
      end

      def figure(node, target)
        block(node[:target], target) if node[:target]
        if node[:caption] && !node[:caption].empty?
          style = text_style("figure.caption")
          target.formatted_text(inline_runs(node[:caption], italic: true, font_family: style[:font]),
                                **style)
        end
      end

      # A composite figure (PART 9 section 4c) is ONE float. Its panels, the
      # stray content preserved between them and the group caption are laid out
      # as a single box that a page break may not enter, so the caption cannot
      # be stranded from the panels it numbers, nor a panel from its own
      # caption.
      #
      # PANELS ARE THE `figure` AND `table` CHILDREN, in source order; every
      # other child is plain group content and is drawn IN PLACE between them.
      # Nothing here re-attaches or drops it.
      #
      # THE GROUP CAPTION IS ALREADY NUMBERED when it arrives: the number is a
      # `caption_number` inline the engine resolved, and a `#` placeholder in a
      # PANEL caption stayed literal because a panel draws nothing from the
      # document sequence. Neither is this renderer's decision.
      def figure_group(node, target)
        style = style_for("figure.group", with_box: true)
        panels = ::HexaPDF::Document::Layout::ChildrenCollector.collect(@layout) do |cont|
          Array(node[:children]).each do |child|
            case child[:type]
            when "figure", "table" then panel(child, cont)
            else block(child, cont)
            end
          end
        end
        columns = column_count(node, style)
        body = if columns > 1
                 [@layout.box(:column, children: panels, columns: columns, gaps: style[:column_gap])]
               else
                 panels
               end
        body += [group_caption_box(node[:caption])] if node[:caption] && !node[:caption].empty?
        emit_box(keep_together(body, style: style[:box]), target)
      end

      # A panel keeps its host and its own caption on one page too - a caption
      # that says "(a)" is worth nothing on the page after its image. A `table`
      # panel keeps the table's own caption, which the table renderer draws;
      # the panel wrapper adds nothing to it.
      def panel(node, target)
        children = ::HexaPDF::Document::Layout::ChildrenCollector.collect(@layout) do |cont|
          node[:type] == "table" ? table(node, cont) : figure(node, cont)
        end
        emit_box(keep_together(children), target)
      end

      def group_caption_box(caption)
        style = text_style("figure.group.caption")
        @layout.formatted_text_box(inline_runs(caption, bold: true, font_family: style[:font]),
                                   **style)
      end

      # `.columns-N` from the attribute line is a LAYOUT HINT, not content: it
      # is honored when the page is wide enough to give every column
      # +min_column_width+, and ignored in favor of a stack when it is not. The
      # panels render either way, in source order, so no hint can cost the
      # document a panel.
      def column_count(node, style)
        attrs = node[:attrs]
        classes = attrs.is_a?(Hash) ? Array(attrs[:classes]) : []
        hint = classes.filter_map { |c| c.to_s[/\Acolumns-(\d+)\z/, 1] }.last
        return 1 if hint.nil?

        count = hint.to_i
        return 1 if count < 2

        gaps = style[:column_gap].to_f * (count - 1)
        return 1 if (@c.frame.width - gaps) / count < style[:min_column_width].to_f

        count
      end

      # A non-splitable box that does not fit even an empty page does not
      # degrade - HexaPDF raises "Box didn't fit multiple times", which loses
      # the WHOLE document over one oversized figure. So the box is fitted
      # against a full page first, and a group that cannot be kept together is
      # allowed to split instead: page breaks inside it, panels still in source
      # order, which is what splitting a container box preserves.
      def keep_together(children, style: nil)
        box = @layout.box(:container, children: children, splitable: false, style: style || {})
        return box if fits_on_a_page?(box)

        @layout.box(:container, children: children, splitable: true, style: style || {})
      end

      def fits_on_a_page?(box)
        width = @c.frame.width
        height = @c.frame.height
        box.fit(width, height, ::HexaPDF::Layout::Frame.new(0, 0, width, height)).success?
      rescue StandardError
        false
      end

      # +target+ is the composer at the top level and a children collector
      # inside any container; only the former draws.
      def emit_box(box, target)
        target.respond_to?(:draw_box) ? target.draw_box(box) : target << box
      end

      def image_block(node, target)
        io = resolve_image(node[:src].to_s)
        if io
          target.image(io, **style_for("image"))
        else
          alt = resolve_nbsp(node[:alt])
          alt = "[image: #{node[:src]}]" if alt.empty?
          target.formatted_text([{ text: alt, font: [base_font, { variant: :italic }] }],
                                margin: [0, 0, BLOCK_GAP])
        end
      end

      def display_math(node, target)
        if (bytes = call_renderer(:math, node[:content].to_s, true))
          return image_bytes(bytes, target, align: :center)
        end

        style = style_for("math", with_box: true)
        box = style.delete(:box)
        style[:font] ||= code_font
        target.text(node[:content].to_s, **style, text_align: :center, box_style: box)
      end

      def thematic_break(target)
        style = style_for("thematic_break")
        height = style.delete(:height)
        target.box(:base, height: height, style: style)
      end

      # Draw a rendered image ({bytes:, width:, height:} or raw bytes) as a
      # block image. :width/:height are box constructor arguments in HexaPDF,
      # not style properties.
      def image_bytes(img, target, align: nil)
        img = { bytes: img } if img.is_a?(String)
        style = style_for("image")
        style[:align] = align if align
        opts = { style: style }
        opts[:width] = img[:width] if img[:width]
        opts[:height] = img[:height] if img[:height]
        target.image(StringIO.new(img[:bytes]), **opts)
      rescue StandardError
        # A malformed image must not abort the whole document.
        nil
      end

      # ---- tables (with row/col spans) -----------------------------------

      def table(node, target)
        resolved = resolve_spans(Array(node[:rows]))
        return if resolved.empty?

        header_count = resolved.first.any? { |o| o[:header] } ? 1 : 0
        table_style = style_for("table")
        header_style = style_for("table.header")

        cell_boxes = resolved.map do |row|
          row.map do |o|
            cell_style = o[:header] ? table_style.merge(header_style) : table_style
            runs = inline_runs(o[:cell][:children], bold: o[:header],
                               font_family: cell_style[:font])
            runs = [{ text: "" }] if runs.empty?
            # :margin belongs to the table box, :cell_padding is our pseudo-prop.
            box_opts = cell_style.except(:margin, :cell_padding, :box)
            box_opts[:padding] = cell_style[:cell_padding]
            box = @layout.formatted_text_box(runs, **box_opts)
            hash = { content: box }
            hash[:col_span] = o[:col_span] if o[:col_span] > 1
            hash[:row_span] = o[:row_span] if o[:row_span] > 1
            hash
          end
        end

        header = header_count.positive? ? ->(_t) { [cell_boxes.first] } : nil
        body = header_count.positive? ? cell_boxes[1..] : cell_boxes
        body = [[{ content: @layout.text_box("") }]] if body.nil? || body.empty?

        target.table(body, header: header, margin: table_style[:margin])
        if node[:caption] && !node[:caption].empty?
          style = text_style("table.caption")
          target.formatted_text(inline_runs(node[:caption], italic: true, font_family: style[:font]),
                                **style)
        end
      end

      # Resolve Carve's explicit span markers (a `<` cell = merge left, a `^`
      # cell = merge up) into per-cell col_span / row_span counts, returning
      # rows of originator hashes {cell:, header:, col_span:, row_span:} with
      # marker cells dropped. Every covered grid position is explicit in Carve,
      # so a cell's column index equals its position in the row.
      def resolve_spans(rows)
        col_owner = {} # column index => originator hash currently owning it
        out = []
        rows.each do |row|
          emitted = []
          last = nil
          bumped = {} # originators already row-extended in THIS row (by object id)
          Array(row[:cells]).each_with_index do |cell, col|
            case cell[:span]
            when "colspan"
              owner = last || col_owner[col - 1]
              owner[:col_span] += 1 if owner
              col_owner[col] = owner if owner
            when "rowspan"
              owner = col_owner[col]
              # A multi-column cell has one `^` per covered column on the next
              # row; count the downward extension only once per originator.
              if owner && !bumped[owner.object_id]
                owner[:row_span] += 1
                bumped[owner.object_id] = true
              end
              # col_owner[col] stays pointing at the same originator so a
              # further `^` in the next row chains onto it.
            else
              o = { cell: cell, header: cell[:header], col_span: 1, row_span: 1 }
              emitted << o
              last = o
              col_owner[col] = o
            end
          end
          out << emitted
        end
        out
      end

      # ---- inline flattening ---------------------------------------------

      def inline_runs(nodes, **ctx)
        out = []
        Array(nodes).each { |n| emit_inline(n, ctx, out) }
        out
      end

      def emit_inline(node, ctx, out)
        case node[:type]
        when "text"       then out << run(node[:value].to_s, ctx)
        when "soft_break" then out << run(" ", ctx)
        when "hard_break" then out << { text: "\n" }
        # Each emphasis sort is its OWN node type. They used to be one
        # `emphasis` node carrying a `kind`, so a profile could not deny bold
        # while allowing italic and nothing could name them apart (carve-rb#32).
        # Matching only `emphasis` meant `*bold*` fell through to the default
        # branch: the text still rendered, in the regular face, with nothing to
        # report.
        when "strong", "emphasis", "underline", "strike",
             "superscript", "subscript", "highlight"
          emit_children(node, emphasis_ctx(ctx, node), out)
        when "span"       then emit_children(node, ctx, out)
        when "code"       then out << run(node[:value].to_s, ctx.merge(code: true))
        when "math"       then inline_math(node, ctx, out)
        when "link"
          lctx = ctx.merge(link: node[:href].to_s)
          if node[:children] && !node[:children].empty?
            node[:children].each { |c| emit_inline(c, lctx, out) }
          else
            out << run(node[:href].to_s, lctx)
          end
        when "autolink" then out << run(node[:href].to_s, ctx.merge(link: node[:href].to_s))
        when "image"    then inline_image(node, ctx, out)
        # `symbol` is what `:name:` publishes now; `emoji` was its name before
        # the rename and is still accepted, the same way the footnote arm below
        # still accepts `footnote`. Both print the shortcode, which is what the
        # reference engine's plain-text target does with an unresolved one.
        when "symbol", "emoji" then out << run(":#{node[:name]}:", ctx)
        # The inline literal of PART 9 section 27 - a code span with the wrapper
        # dropped. There is no wrapper in a PDF text run, so what is left is the
        # content, unstyled: carve-js renders `A !`raw span` B` as `A raw span B`
        # in plain text.
        when "literal_inline" then out << run(node[:content].to_s, ctx)
        # The number in "Figure 1:". Without this the caption renders without it.
        when "caption_number" then out << run(node[:n].to_s, ctx)
        # `:name[content]` - the content is an inline array, and the extension's
        # own presentation has no PDF form, so emit what it wraps. carve-js
        # renders `:kbd[Ctrl]` as `Ctrl` in plain text.
        when "inline_extension" then inline_extension(node, ctx, out)
        when "mention"  then out << run("@#{node[:user]}", ctx)
        when "tag"      then out << run("##{node[:name]}", ctx)
        # `footnote_ref` is `[^label]` and `inline_footnote` is `^[body]`.
        # Both used to publish as `footnote`, which is the BLOCK definition's
        # type - one identifier for three constructs, so nothing could tell them
        # apart (carve-rb#19). The old name is still accepted: a tree stored by
        # an older version can still be rendered.
        when "footnote_ref", "inline_footnote", "footnote"
          number = register_footnote(node)
          out << run("[#{number}]", ctx.merge(super: true)) if number
        when "citation_group" then out << run(node[:raw].to_s, ctx)
        when "abbreviation"   then out << run(node[:abbr].to_s, ctx)
        when "cross_ref"      then out << run(node[:target].to_s, ctx)
        when "caption_number" then (out << run(node[:number].to_s, ctx) if node[:number])
        when "critic_insert"  then emit_children(node, ctx.merge(underline: true), out)
        when "critic_delete"  then emit_children(node, ctx.merge(strike: true), out)
        when "critic_substitute" then out << run(node[:new_text].to_s, ctx.merge(underline: true))
        when "smart_punctuation" then out << run(smart_punctuation_text(node), ctx)
        # A character the author escaped. The backslash is authoring syntax, so
        # the page shows the character - but the node has no children, so
        # without this arm it falls through to the branch that emits children
        # and renders nothing at all (carve#350, carve#355).
        when "escaped_text" then out << run(node[:value].to_s, ctx)
        when "raw_inline", "critic_comment"
          # No safe PDF form - drop.
        else
          emit_children(node, ctx, out) if node[:children]
        end
      end

      # Canonical glyph per smart-typography kind (Carve spec PART 9 section 8).
      # Quote kinds are deliberately absent: their glyph is locale-dependent and
      # is resolved during parsing, so the node carries it.
      SMART_PUNCTUATION_GLYPHS = {
        "ellipsis" => "\u{2026}",
        "em_dash" => "\u{2014}",
        "en_dash" => "\u{2013}",
        "left_right_arrow" => "\u{2194}",
        "rightwards_arrow" => "\u{2192}",
        "leftwards_arrow" => "\u{2190}",
        "rightwards_double_arrow" => "\u{21D2}",
        "less_than_or_equal" => "\u{2264}",
        "greater_than_or_equal" => "\u{2265}",
        "not_equal" => "\u{2260}",
        "plus_minus" => "\u{00B1}",
        "copyright" => "\u{00A9}",
        "registered" => "\u{00AE}",
        "trademark" => "\u{2122}"
      }.freeze

      # A typographic substitution is its own node rather than text (spec PART 9
      # section 8), carrying the resolved kind AND the author's source run.
      #
      # Before this existed here, the node fell through to the else branch,
      # which emits children - and this node has none - so every quote,
      # apostrophe, dash and ellipsis vanished from the rendered PDF with no
      # error. That is why the resolution order matters: prefer the glyph the
      # parser fixed (quotes are locale-dependent), then the kind table, and
      # only fall back to the author's source run if a future kind arrives that
      # this table does not know. Dropping to source text renders three dots
      # instead of an ellipsis, which is wrong but visible; dropping the node
      # renders nothing, which is not.
      def smart_punctuation_text(node)
        glyph = node[:glyph]
        return glyph.to_s unless glyph.nil? || glyph.to_s.empty?

        SMART_PUNCTUATION_GLYPHS.fetch(node[:kind].to_s) { node[:value].to_s }
      end

      def emit_children(node, ctx, out)
        Array(node[:children]).each { |c| emit_inline(c, ctx, out) }
      end

      # Styling for one emphasis node.
      #
      # `/*both*/` is a single `strong` node carrying `boldItalic`, not a
      # `strong` wrapping an `emphasis`, so the italic has to be read off the
      # flag rather than inferred from nesting.
      #
      # The legacy `kind` spelling is still honoured, so a tree stored by an
      # older version renders the same.
      def emphasis_ctx(ctx, node)
        case node[:kind] || node[:type]
        when "strong"
          styled = ctx.merge(bold: true)
          node[:boldItalic] ? styled.merge(italic: true) : styled
        when "emphasis", "italic" then ctx.merge(italic: true)
        when "bold-italic"        then ctx.merge(bold: true, italic: true)
        when "underline"          then ctx.merge(underline: true)
        when "strike"             then ctx.merge(strike: true)
        when "superscript", "super" then ctx.merge(super: true)
        when "subscript", "sub"     then ctx.merge(sub: true)
        when "highlight"          then ctx.merge(highlight: true)
        else ctx
        end
      end

      # Build one formatted-text run hash for +text+ under styling +ctx+.
      # `:name[content]` - the extension's own presentation has no PDF form, so
      # emit what it wraps. `content` is an inline ARRAY in a parsed tree; a
      # hand-built one may hold a bare string, and `render_ast` is public, so
      # take both rather than raising on the second.
      def inline_extension(node, ctx, out)
        content = node[:content]
        case content
        when Array then emit_children({ children: content }, ctx, out)
        when String then out << run(content, ctx)
        end
      end

      # U+E000 STANDS FOR a no-break space the parser resolved - from an escaped
      # space (`a\ b`) or from a line block's preserved indentation (PART 9
      # section 23). PART 12 is explicit that a consumer maps it to its target's
      # no-break space, or to an ordinary space where the target has none, and
      # MUST NOT emit it.
      #
      # A PDF has one, so it maps to U+00A0. Emitting the sentinel is not merely
      # wrong here: the default Type1 font has no glyph for a private-use
      # codepoint, so `a\ b` raised HexaPDF::MissingGlyphError and rendered
      # nothing at all (carve-hexapdf#14).
      RESOLVED_NBSP = "\u{E000}"
      NBSP = "\u{00A0}"

      def resolve_nbsp(text)
        text.to_s.gsub(RESOLVED_NBSP, NBSP)
      end

      def run(text, ctx)
        item = { text: resolve_nbsp(text) }
        if ctx[:code]
          # :box is a block-level pseudo-property (e.g. inherited from a user
          # "code" entry meant for code.block); HexaPDF would read a run :box
          # as an inline box spec and crash.
          item.merge!(@styles.resolve("code.inline").except(:box))
        elsif ctx[:bold] || ctx[:italic]
          variant = if ctx[:bold] && ctx[:italic]
                      :bold_italic
                    elsif ctx[:bold]
                      :bold
                    else
                      :italic
                    end
          item[:font] = [ctx[:font_family] || base_font, { variant: variant }]
        end
        item[:underline] = true if ctx[:underline]
        item[:strikeout] = true if ctx[:strike]
        item[:superscript] = true if ctx[:super]
        item[:subscript] = true if ctx[:sub]
        item.merge!(run_style("highlight")) if ctx[:highlight]
        if ctx[:link] && !ctx[:link].empty?
          item[:link] = ctx[:link]
          item.merge!(run_style("link"))
        end
        item
      end

      # Link/highlight styles are decoration overlays on a run that may already
      # carry a variant or code font; the font they inherit from +base+ must not
      # clobber it (only a font set explicitly on the key itself wins), and a
      # block-level :box pseudo-property must never reach a run.
      def run_style(key)
        style = @styles.resolve(key).except(:box)
        return style if @styles.user_set?(key, :font)

        style.except(:font)
      end

      # Footnote definitions, keyed by label.
      #
      # They used to arrive as a `footnote_defs` MAP ON THE ROOT. PART 12 fixes
      # the root at `type`, `children` and `srcByteLength`, so carve-rb moved
      # them into the tree as `footnote` BLOCK nodes carrying a `label`
      # (carve-rb#19, #21). Reading the old root field found nothing, every
      # reference failed to resolve, and the endnote numbers silently vanished
      # from the PDF - the bodies still rendered, so the page looked plausible.
      #
      # They are collected from anywhere in the tree, not just the top level: a
      # definition written inside a container is still a definition.
      def collect_footnote_defs(doc)
        # The old root map first, so an AST stored by an earlier version still
        # renders - `render_ast` takes whatever the caller kept.
        defs = (doc[:footnote_defs] || {}).transform_keys(&:to_s)
        walk_footnote_defs(doc, defs)
        defs
      end

      def walk_footnote_defs(node, defs)
        return unless node.is_a?(Hash)

        if node[:type] == "footnote" && node[:label]
          defs[node[:label].to_s] ||= Array(node[:children])
        end

        node.each_value do |value|
          case value
          when Array then value.each { |child| walk_footnote_defs(child, defs) }
          when Hash  then walk_footnote_defs(value, defs)
          end
        end
      end

      # Register a footnote occurrence and return its sequential number, or nil
      # when there is nothing to number (unresolvable reference). Repeated
      # references to the same definition share one number and one endnote.
      def register_footnote(node)
        if node[:inline]
          @footnotes << { number: @footnotes.size + 1, inline: node[:inline] }
          return @footnotes.last[:number]
        end

        id = node[:id]
        if id && @footnote_defs.key?(id)
          return @footnote_numbers[id] ||= begin
            @footnotes << { number: @footnotes.size + 1, blocks: @footnote_defs[id] }
            @footnotes.last[:number]
          end
        end

        node[:number]
      end

      # Emit collected footnotes as a numbered endnote section under a short
      # separator rule, mirroring how the HTML renderer relocates footnotes.
      def render_footnotes(target)
        return if @footnotes.empty?

        style = style_for("footnote")
        target.box(:base, height: 1,
                   style: { margin: [14, 380, 6, 0], background_color: "bbbbbb" })
        @footnotes.each do |fn|
          if fn[:inline]
            runs = [{ text: "#{fn[:number]}. " }] +
                   inline_runs(fn[:inline], font_family: style[:font])
            target.formatted_text(runs, **style)
          else
            first_para = true
            Array(fn[:blocks]).each do |blk|
              if first_para && blk[:type] == "paragraph"
                runs = [{ text: "#{fn[:number]}. " }] +
                       inline_runs(blk[:children], font_family: style[:font])
                target.formatted_text(runs, **style)
              else
                block(blk, target)
              end
              first_para = false
            end
          end
        end
      end

      def base_font
        @styles.resolve("base")[:font]
      end

      def code_font
        @styles.resolve("code.inline")[:font]
      end

      def inline_math(node, ctx, out)
        if (img = call_renderer(:math, node[:content].to_s, !!node[:display]))
          spec = { box: [:image, StringIO.new(img[:bytes])],
                   height: img[:height] || 11, valign: :baseline }
          spec[:width] = img[:width] if img[:width]
          out << spec
        else
          out << run(node[:content].to_s, ctx.merge(code: true))
        end
      rescue StandardError
        out << run(node[:content].to_s, ctx.merge(code: true))
      end

      def inline_image(node, ctx, out)
        io = resolve_image(node[:src].to_s)
        if io
          out << { box: [:image, io], height: 12, valign: :baseline }
        else
          alt = node[:alt].to_s
          out << run(alt.empty? ? "[image]" : alt, ctx.merge(italic: true))
        end
      rescue StandardError
        out << run(node[:alt].to_s.empty? ? "[image]" : node[:alt].to_s, ctx.merge(italic: true))
      end

      # Resolve an image source to something HexaPDF can load: a local file
      # path, or a decoded +data:+ URI (as a StringIO). Returns nil for remote
      # URLs or unreadable sources (no network fetching).
      def resolve_image(src)
        return nil if src.empty?

        if src.start_with?("data:")
          meta, data = src.split(",", 2)
          return nil unless data

          bytes = meta.include?(";base64") ? Base64.decode64(data) : data
          return StringIO.new(bytes)
        end
        return src if File.file?(src)

        nil
      end

      # Invoke a renderer callable; returns {bytes:, width:, height:} or nil.
      # Callables may return raw image bytes (String) or a Hash with :bytes
      # plus optional :width / :height (in points) controlling the drawn size,
      # so high-DPI rasters can embed at their intended dimensions.
      def call_renderer(key, *args)
        callable = @renderers[key] || @renderers[key.to_s]
        return nil unless callable

        result = callable.call(*args)
        result = { bytes: result } if result.is_a?(String)
        return nil unless result.is_a?(Hash) && result[:bytes].is_a?(String)

        result
      rescue StandardError
        nil
      end

      def inline_children?(children)
        Array(children).any? { |c| INLINE_TYPES.include?(c[:type]) }
      end

      INLINE_TYPES = %w[
        text emphasis code link image span math raw_inline emoji autolink
        cross_ref caption_number mention tag citation_group inline_extension
        abbreviation footnote soft_break hard_break critic_insert critic_delete
        critic_substitute critic_comment
      ].freeze
    end
  end
end
