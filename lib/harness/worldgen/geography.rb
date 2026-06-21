module Harness
  module Worldgen
    # Vector geography — water-first, NO raster grid.
    #
    # The river walk only ever needs to READ elevation along its path, and
    # elevation is a continuous Noise function, so the whole thing runs in
    # continuous space and emits river POLYLINES instead of painting a grid:
    #
    #   1. Elevation — edge-shaped noise (margins sink to sea → a coherent
    #      coastline around a central landmass), sampled pointwise on demand.
    #   2. Sea       — the low region: elevation(x,y) < sea_level. A land point
    #      with sea nearby is `coastal`.
    #   3. Rivers    — the downhill walk in continuous space: from a high source,
    #      step toward the lowest neighbour of lower-or-equal elevation (strict
    #      descent preferred; equal steps allowed across flats but never back
    #      the way we came — that, plus a step cap, prevents dithering) until we
    #      reach the sea (a river MOUTH) or get boxed in by higher ground (a
    #      closed basin → a LAKE). Output: a handful of polylines.
    #   4. Moisture  — base noise + a proximity boost from sea and rivers.
    #
    # Deterministic from the seed: only the seed + params + the few river
    # polylines need persisting; everything else regenerates by sampling. This
    # EXTENDS the existing "sample a fact at a point" model (see Biome) rather
    # than replacing it with a grid substrate. Terrain-type classification
    # (marsh / forest / crags / coast / …) layers on top of these queries in a
    # separate pass.
    class Geography
      DEFAULT_SEA_LEVEL  = 0.34
      DEFAULT_RIVERS     = 7

      ELEV_SCALE         = 0.045  # noise frequency for elevation (smaller = bigger landmasses)
      ELEV_OCTAVES       = 4
      MOIST_SCALE        = 0.06
      EDGE_FALLOFF       = 0.16   # outer fraction of the map that ramps down to sea

      RIVER_STEP         = 1.5    # continuous step length of the walk
      RIVER_MAX_STEPS    = 500    # safety cap (the anti-dither guard already bounds it)
      SOURCE_SAMPLES     = 240    # random points considered when picking high river sources
      EPS                = 1e-6

      COAST_RADIUS       = 2.5    # sea within this of a land point → coastal
      RIVER_RADIUS       = 2.0    # river/lake within this → riverside
      MOIST_WATER_RADIUS = 8.0    # water proximity stops boosting moisture past this
      MOIST_WATER_BOOST  = 0.4    # max wetness a body of water adds nearby

      DIRS8 = [ [ 1, 0 ], [ -1, 0 ], [ 0, 1 ], [ 0, -1 ],
                [ 1, 1 ], [ 1, -1 ], [ -1, 1 ], [ -1, -1 ] ].freeze

      # A river is a polyline; `ends_in` is :sea (a mouth) or :lake (a basin).
      River = Struct.new(:points, :ends_in, keyword_init: true) do
        def mouth = points.last
      end

      attr_reader :seed, :size, :sea_level, :rivers

      def self.generate(seed:, size: Generator::DEFAULT_SIZE, sea_level: DEFAULT_SEA_LEVEL, rivers: DEFAULT_RIVERS)
        new(seed: seed, size: size, sea_level: sea_level, river_count: rivers).tap(&:build)
      end

      # Rebuild from a persisted world: same seed → same fields, but the river
      # polylines are restored from storage rather than re-walked (cheaper, and
      # immune to later tweaks of the carving algorithm reshaping old worlds).
      def self.restore(seed:, size:, sea_level:, rivers:)
        geo = new(seed: seed, size: size, sea_level: sea_level, river_count: Array(rivers).size)
        geo.load_rivers(rivers)
        geo
      end

      def initialize(seed:, size:, sea_level:, river_count:)
        @seed        = seed
        @size        = size
        @sea_level   = sea_level
        @river_count = river_count
        @noise       = Noise.new(seed: seed)
        @rng         = Random.new((seed.to_i ^ 0x21A7E2) & 0xFFFFFFFF)
        @rivers      = []
      end

      def build
        @rivers = carve_rivers
        self
      end

      # JSON-safe river polylines for persistence (the only precomputed artifact;
      # everything else regenerates from the seed). Round-trips through `restore`.
      def rivers_payload
        @rivers.map { |r| { "points" => r.points.map { |x, y| [ x, y ] }, "ends_in" => r.ends_in.to_s } }
      end

      def load_rivers(payload)
        @rivers = Array(payload).map do |r|
          h = r.respond_to?(:to_h) ? r.to_h : r
          pts = (h["points"] || h[:points] || []).map { |x, y| [ x.to_f, y.to_f ] }
          River.new(points: pts, ends_in: (h["ends_in"] || h[:ends_in]).to_sym)
        end
      end

      # Lake points (the terminal of each basin-ending river) — water bodies in
      # their own right, surfaced for rendering and water-proximity.
      def lakes
        @rivers.select { |r| r.ends_in == :lake }.map(&:mouth)
      end

      # ---- continuous-field queries (sampled on demand, no stored grid) ----

      # Elevation in [0,1], shaped so the map margins sink to sea.
      def elevation(x, y)
        @noise.at(x * ELEV_SCALE, y * ELEV_SCALE, octaves: ELEV_OCTAVES) * edge_factor(x, y)
      end

      def sea?(x, y)
        elevation(x, y) < @sea_level
      end

      def coastal?(x, y)
        return false if sea?(x, y)
        ring(x, y, COAST_RADIUS).any? { |px, py| sea?(px, py) }
      end

      def riverside?(x, y)
        return false if sea?(x, y)
        nearest_river_distance(x, y) <= RIVER_RADIUS
      end

      # Wetness in [0,1]: base noise plus a falloff boost from nearby sea/river.
      def moisture(x, y)
        base = @noise.at(x * MOIST_SCALE + 1000.0, y * MOIST_SCALE + 1000.0)
        boost = [ water_boost(distance_to_sea(x, y)),
                  water_boost(nearest_river_distance(x, y)) ].max
        (base + boost).clamp(0.0, 1.0)
      end

      private

      # 1.0 in the interior, ramping to 0 within EDGE_FALLOFF of any border so
      # the landmass is wrapped in ocean rather than cut off square.
      def edge_factor(x, y)
        m  = @size * EDGE_FALLOFF
        fx = [ [ x, @size - x ].min / m, 1.0 ].min
        fy = [ [ y, @size - y ].min / m, 1.0 ].min
        [ fx, fy, 1.0 ].min.clamp(0.0, 1.0)
      end

      def in_bounds?(x, y)
        x >= 0 && y >= 0 && x <= @size && y <= @size
      end

      def carve_rivers
        river_sources.map { |sx, sy| trace_river(sx, sy) }
      end

      # High, land sources: sample random points, keep the land ones, take the
      # highest pool, draw river_count of them deterministically.
      def river_sources
        cand = Array.new(SOURCE_SAMPLES) { [ @rng.rand * @size, @rng.rand * @size ] }
                    .reject { |x, y| sea?(x, y) }
                    .sort_by { |x, y| -elevation(x, y) }
        pool = cand.first([ @river_count * 4, 8 ].max)
        return [] if pool.empty?
        pool.sample([ @river_count, pool.size ].min, random: @rng)
      end

      # The downhill walk in continuous space.
      def trace_river(sx, sy)
        pts   = [ [ sx, sy ] ]
        cx, cy = sx, sy
        cur_e = elevation(cx, cy)
        prev  = nil

        RIVER_MAX_STEPS.times do
          return River.new(points: pts, ends_in: :sea) if sea?(cx, cy)

          nxt = next_step(cx, cy, cur_e, prev)
          return River.new(points: pts, ends_in: :lake) if nxt.nil? # boxed in by higher ground

          prev   = [ cx, cy ]
          cx, cy = nxt
          cur_e  = elevation(cx, cy)
          pts << [ cx, cy ]
        end

        # Cap reached (rare) — treat the stall as a basin.
        River.new(points: pts, ends_in: :lake)
      end

      # Lowest neighbour of lower-or-equal elevation; prefer a strict descent,
      # accept an equal step only if it doesn't double back toward `prev` (the
      # anti-dither guard). nil when every direction climbs.
      def next_step(cx, cy, cur_e, prev)
        strict = nil; strict_e = nil
        equal  = nil; equal_e  = nil
        DIRS8.each do |dx, dy|
          nx = cx + dx * RIVER_STEP
          ny = cy + dy * RIVER_STEP
          next unless in_bounds?(nx, ny)
          e = elevation(nx, ny)
          if e < cur_e - EPS
            (strict, strict_e = [ nx, ny ], e) if strict_e.nil? || e < strict_e
          elsif e <= cur_e + EPS && !backtrack?(nx, ny, prev)
            (equal, equal_e = [ nx, ny ], e) if equal_e.nil? || e < equal_e
          end
        end
        strict || equal
      end

      def backtrack?(nx, ny, prev)
        return false unless prev
        Math.hypot(nx - prev[0], ny - prev[1]) < RIVER_STEP * 0.5
      end

      # Min distance from a point to any river polyline segment (incl. lake
      # ends). Rivers are short, queries infrequent — linear scan is fine.
      def nearest_river_distance(x, y)
        best = Float::INFINITY
        @rivers.each do |r|
          r.points.each_cons(2) do |(ax, ay), (bx, by)|
            d = point_segment_distance(x, y, ax, ay, bx, by)
            best = d if d < best
          end
          # single-point rivers (degenerate) — distance to the point
          if r.points.size == 1
            px, py = r.points.first
            d = Math.hypot(x - px, y - py)
            best = d if d < best
          end
        end
        best
      end

      def point_segment_distance(px, py, ax, ay, bx, by)
        dx = bx - ax; dy = by - ay
        len2 = dx * dx + dy * dy
        return Math.hypot(px - ax, py - ay) if len2 <= EPS
        t = (((px - ax) * dx) + ((py - ay) * dy)) / len2
        t = t.clamp(0.0, 1.0)
        Math.hypot(px - (ax + t * dx), py - (ay + t * dy))
      end

      # Approximate distance to sea by expanding ring samples; capped.
      def distance_to_sea(x, y)
        return 0.0 if sea?(x, y)
        r = COAST_RADIUS
        while r <= MOIST_WATER_RADIUS
          return r if ring(x, y, r).any? { |px, py| sea?(px, py) }
          r += COAST_RADIUS
        end
        Float::INFINITY
      end

      def water_boost(dist)
        return 0.0 if dist.nil? || dist >= MOIST_WATER_RADIUS
        (1.0 - dist / MOIST_WATER_RADIUS) * MOIST_WATER_BOOST
      end

      # Eight points on a circle of radius r around (x,y) — cheap proximity probe.
      def ring(x, y, r)
        DIRS8.map { |dx, dy| [ x + dx * r, y + dy * r ] }
             .select { |px, py| in_bounds?(px, py) }
      end
    end
  end
end
