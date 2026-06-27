module Harness
  module Worldgen
    # Render a Map as ASCII for inspection. Three-layer:
    #   - background: terrain at each cell (from map.geography); blank when a map
    #     has no geography (hand-built test maps).
    #   - rivers: river polylines rasterized over the terrain as '+', lakes 'o'.
    #   - foreground: city marker (kingdom_id digit; letter if > 9 kingdoms).
    #
    # Default rendering is 60 columns wide; rows scale to keep aspect ratio.
    # Cells are sampled by mapping (col, row) → (x, y) on the continuous field.
    module Ascii
      DEFAULT_WIDTH = 60

      # Terrain → glyph. Grouped for legibility rather than one char per type.
      TERRAIN_GLYPH = {
        sea:            "~",
        coastal:        ":",
        river_valley:   ".",
        marsh:          "%",
        floodplain:     ",",
        grassland:      ".",
        moor:           "\"",
        forest_lowland: "t",
        forest_upland:  "T",
        crags:          "n",
        mountain:       "^"
      }.freeze

      RIVER_GLYPH = "+".freeze
      LAKE_GLYPH  = "o".freeze

      # Terrain → ANSI foreground code (only applied when color: true). Chosen to
      # read at a glance: water blue, lowland greens, wetlands cyan, uplands
      # brown/grey, mountains bright white. Rivers/lakes/cities painted separately.
      TERRAIN_COLOR = {
        sea:            34,  # blue
        coastal:        33,  # sand/yellow
        river_valley:   32,  # green
        marsh:          36,  # cyan (wetland)
        floodplain:     32,  # green
        grassland:      92,  # bright green
        moor:           33,  # brown/yellow
        forest_lowland: 32,  # green
        forest_upland:  32,  # green (the t/T glyph carries the elevation)
        crags:          90,  # grey
        mountain:       97   # bright white
      }.freeze
      RIVER_COLOR = 96  # bright cyan
      LAKE_COLOR  = 94  # bright blue
      CITY_COLOR  = 93  # bold bright yellow — markers pop against terrain

      def self.render(map, width: DEFAULT_WIDTH, color: false)
        grid = map.geography ? build_grid_with_terrain(map, width, color) : build_grid_blank(map, width)
        draw_rivers!(grid, map, width, color) if map.geography
        place_cities!(grid, map, width, color)
        legend = build_legend(map)
        ([ horizontal_rule(width) ] + grid.map(&:join) + [ horizontal_rule(width) ] + legend).join("\n")
      end

      # Wrap a glyph in an ANSI SGR sequence when color is on; otherwise return
      # it bare. `bold` adds intensity (used for city markers). Zero display
      # width, so the fixed-width horizontal rule still lines up.
      def self.paint(glyph, code, color, bold: false)
        return glyph unless color
        prefix = bold ? "\e[1;#{code}m" : "\e[#{code}m"
        "#{prefix}#{glyph}\e[0m"
      end

      def self.build_grid_with_terrain(map, width, color = false)
        geo    = map.geography
        scale  = map.size.to_f / width
        height = (map.size.to_f / scale / 2).round
        Array.new(height) do |row|
          Array.new(width) do |col|
            x = col * scale
            y = row * scale * 2
            t = Terrain.at(geo: geo, x: x, y: y)
            paint(TERRAIN_GLYPH.fetch(t, "."), TERRAIN_COLOR.fetch(t, 37), color)
          end
        end
      end

      # Rasterize each river polyline + lake endpoint onto the grid.
      def self.draw_rivers!(grid, map, width, color = false)
        height = grid.size
        scale  = map.size.to_f / width
        map.geography.rivers.each do |river|
          river.points.each do |x, y|
            col = (x / scale).round
            row = (y / (scale * 2)).round
            next unless row.between?(0, height - 1) && col.between?(0, width - 1)
            grid[row][col] = paint(RIVER_GLYPH, RIVER_COLOR, color)
          end
          if river.ends_in == :lake
            lx, ly = river.mouth
            col = (lx / scale).round
            row = (ly / (scale * 2)).round
            grid[row][col] = paint(LAKE_GLYPH, LAKE_COLOR, color) if row.between?(0, height - 1) && col.between?(0, width - 1)
          end
        end
      end

      def self.build_grid_blank(map, width)
        scale  = map.size.to_f / width
        height = (map.size.to_f / scale / 2).round
        Array.new(height) { Array.new(width, ".") }
      end

      def self.place_cities!(grid, map, width, color = false)
        height = grid.size
        scale  = map.size.to_f / width
        map.cities.each do |c|
          col = (c.x / scale).round.clamp(0, width - 1)
          row = (c.y / (scale * 2)).round.clamp(0, height - 1)
          grid[row][col] = paint(kingdom_marker(c.kingdom_id), CITY_COLOR, color, bold: true)
        end
      end

      def self.kingdom_marker(id)
        # Player-created wilderness (wilderness_leaf) is a top-level coordinated
        # location with no kingdom — it lands here with a nil id. Mark it as
        # uncharted rather than crashing on the comparison.
        return "*" if id.nil?
        return id.to_s if id < 10
        ("A".ord + (id - 10)).chr
      end

      def self.build_legend(map)
        lines = []
        lines << "kingdoms (#{map.kingdoms.size}):"
        map.kingdoms.each do |k|
          anchor = map.cities[k.anchor_city_id]
          members = map.cities.count { |c| c.kingdom_id == k.id }
          name = k.name || "(unnamed)"
          lines << "  [#{kingdom_marker(k.id)}] #{name}  members=#{members}  anchor=city##{anchor.id} at (#{'%.1f' % anchor.x}, #{'%.1f' % anchor.y})"
        end
        lines << ""
        lines << "cities (#{map.cities.size}):"
        map.cities.each do |c|
          name = c.name || "(unnamed)"
          terr = c.terrain ? "  #{c.terrain}#{c.coastal ? ' coastal' : ''}#{c.riverside ? ' riverside' : ''}" : "  #{c.biome}"
          prof = c.economic_basis ? "  {#{c.size} · #{c.economic_basis} · #{c.wealth}}" : ""
          lines << "  city##{c.id} [#{kingdom_marker(c.kingdom_id)}] #{name}  (#{'%.1f' % c.x}, #{'%.1f' % c.y})#{terr}#{prof}"
        end
        lines
      end

      def self.horizontal_rule(width)
        "+" + "-" * width + "+"
      end
    end
  end
end
