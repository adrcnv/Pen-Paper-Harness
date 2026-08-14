module Harness
  # Terminal presentation helpers for the play loop. Pure string → string; no
  # state, no LLM.
  #
  #   - narration(...) highlights, in the rendered turn: quoted speech (green),
  #     names the world HAS A ROW FOR (cyan, incl. a trailing possessive 's),
  #     and the mechanical roll scoreboard (dim bracket, tiered outcome). It
  #     does NOT flag "unknown" names — that yellow validator broke the fourth
  #     wall (and lit up every not-yet-committed name); the logs are the
  #     narrative-shift validator now, not the prose.
  #   - rule(...) is the between-turns separator.
  #
  # All colour is opt-in (color:); bin/play passes $stdout.tty? so piping to a
  # file stays clean.
  module Render
    RESET       = "\e[0m"
    KNOWN_COLOR = "\e[1;36m" # bold cyan — the world has a row for this name
    RULE_COLOR  = "\e[2m"    # dim
    DIM         = "\e[2m"
    QUOTE_COLOR = "\e[32m"   # green — spoken text
    # Quoted speech — the local model uses double AND single quotes freely, so
    # we colour both rather than fighting it in the prompt. Two branches:
    #   1. double (straight/curly): unambiguous, simple.
    #   2. single (straight/curly): ambiguous with apostrophes (rain's, doesn't),
    #      so a delimiter is a quote NOT flanked by letters — the opening isn't
    #      preceded by a letter, the closing isn't followed by one — while a
    #      word-internal apostrophe (quote-followed-by-letter) is allowed THROUGH
    #      the span rather than ending it. So 'The rain's steady' colours whole.
    QUOTE_RE    = /["“][^"”\n]*["”]|(?<!\p{L})['‘](?:[^'‘’\n]|['’](?=\p{L}))*['’](?!\p{L})/
    # An optional trailing possessive, so a known name colours through its 's
    # ("Hilde's" → all cyan), straight or curly apostrophe.
    POSSESSIVE  = /(?:['’]s)?/

    # The mechanical scoreboard line the system renders above prose:
    #   [<action> — <Stat/Ability> <roll> vs <against>: <outcome>, <margin>]
    # The bracket is dimmed (secondary to the prose); the OUTCOME token is
    # recoloured by tier so pass/fail/crit reads at a glance. Detection is
    # exact — these strings come from the engine, not the model.
    BRACKET_RE = /\[[^\]\n]*\]/
    OUTCOMES   = %w[critical_success critical_failure success failure].freeze
    OUTCOME_COLOR = {
      "critical_success" => "\e[1;32m", # bold green
      "critical_failure" => "\e[1;31m", # bold red
      "success"          => "\e[32m",   # green
      "failure"          => "\e[31m"    # red
    }.freeze

    module_function

    # Pull every entity name the world currently records. Cheap (three plucks),
    # called once per turn. Returns [] if the models aren't loaded.
    def entity_names
      (::Character.pluck(:name) + ::Faction.pluck(:name) + ::Location.pluck(:name)).compact
    rescue StandardError
      []
    end

    # Colorize a rendered turn: quoted speech (green), known entity names (cyan,
    # through a trailing 's), and the mechanical roll scoreboard (dim bracket,
    # tiered outcome). Brackets/quotes are collected first and the name pass
    # skips anything inside them. color:false returns text verbatim.
    def narration(text, known_names: [], color: true)
      text = text.to_s
      return text unless color && !text.empty?

      spans = []
      kre = known_regex(known_names)
      collect_brackets!(spans, text)
      collect_quotes!(spans, text, kre)
      collect_named!(spans, text, kre, KNOWN_COLOR) if kre
      stitch(text, spans)
    end

    # A dim separator between turns, centred ornament.
    def rule(width: 72, color: true)
      bar  = "─" * ((width - 3) / 2)
      line = "#{bar}◆#{bar}"
      color ? "#{RULE_COLOR}#{line}#{RESET}" : line
    end

    CARD_COLOR = "\e[33m" # ochre — the mechanical arrival card

    # Render a turn's typed parts ({kind:, text:}), one styled block per part.
    # Kinds carry the styling: cards ochre, stock lines dim, everything else
    # through narration() (quotes green, known names cyan, brackets painted).
    # Styling lives HERE only — the buffer and every LLM payload store the
    # plain join, never ANSI.
    def parts(list, known_names: [], color: true)
      Array(list).filter_map { |p|
        text = (p[:text] || p["text"]).to_s
        next nil if text.strip.empty?
        case (p[:kind] || p["kind"]).to_s
        when "card"  then color ? "#{CARD_COLOR}#{text}#{RESET}" : text
        when "stock" then color ? "#{DIM}#{text}#{RESET}" : text
        else narration(text, known_names: known_names, color: color)
        end
      }.join("\n\n")
    end

    COMBAT_COLOR = "\e[1;31m" # bold red — you are in a fight

    # A mechanical "you are in combat" banner, shown after the turn's prose
    # while a fight is running. The state machine swaps to the combat tool
    # surface silently, so without this the player can't tell a brawl from a
    # chat (the failure this fixes). `allies` / `foes` are arrays of
    # [name, current_hp, max_hp]; the player should be among allies.
    def combat_banner(round:, allies:, foes:, color: true)
      head  = "⚔ IN COMBAT — round #{round}"
      you   = allies.map { |n, hp, mx| "#{n} #{hp}/#{mx}" }.join("   ")
      them  = foes.map   { |n, hp, mx| "#{n} #{hp}/#{mx}" }.join("   ")
      lines = [ head, "  you:  #{you}", "  foes: #{them}" ]
      return lines.join("\n") unless color
      "#{COMBAT_COLOR}#{head}#{RESET}\n#{DIM}  you:  #{you}\n  foes: #{them}#{RESET}"
    end

    # --- internals -----------------------------------------------------------

    # Leading articles and connectives never colour on their own ("the
    # Evaporation Flats" must not light up every "the").
    NAME_TOKEN_STOP = %w[the a an of].freeze

    # Union of the known names, longest-first so "Blackwood Relay" wins over a
    # bare "Blackwood", word-bounded, plus an optional trailing possessive 's
    # so "Hilde's" colours whole. A multi-word name is usually mentioned by
    # ONE of its parts ("Vesna" for Vesna Krasnov), so distinctive capitalized
    # parts colour too — but tokens match case-SENSITIVELY (a lowercase
    # "watch" must not light up for Oak Watch), while full names keep their
    # case-insensitive match. nil if no names.
    def known_regex(names)
      cleaned = Array(names).compact.map { |n| n.to_s.strip }.reject(&:empty?).uniq
      return nil if cleaned.empty?
      tokens = cleaned.flat_map { |n| n.split(/\s+/) }
                      .select { |t| t.length >= 3 && t.match?(/\A\p{Lu}/) && !NAME_TOKEN_STOP.include?(t.downcase) }
                      .uniq - cleaned
      alts = (cleaned.map { |n| [ n, true ] } + tokens.map { |t| [ t, false ] })
               .sort_by { |s, _| -s.length }
               .map { |s, ci| ci ? "(?i:#{Regexp.escape(s)})" : Regexp.escape(s) }
      /\b(?:#{alts.join('|')})\b#{POSSESSIVE.source}/
    end

    # Each span is [start, end, replacement_string]. Spans are collected in
    # priority order (brackets, then known names, then novel words); a later
    # collector skips any candidate that overlaps an already-claimed span, so
    # priority is enforced at collection and stitch is a plain splice.
    def overlaps?(spans, b, e)
      spans.any? { |s| b < s[1] && s[0] < e }
    end

    # Mechanical scoreboard lines — highest priority, claimed first.
    def collect_brackets!(spans, text)
      text.to_enum(:scan, BRACKET_RE).each do
        m = Regexp.last_match
        spans << [m.begin(0), m.end(0), paint_bracket(m[0])]
      end
    end

    # Dim the whole bracket; recolour the outcome token by tier (longest match
    # first so critical_* wins over success/failure). A bracket with no outcome
    # token is just dimmed.
    def paint_bracket(b)
      outcome = OUTCOMES.find { |o| b.include?(o) }
      return "#{DIM}#{b}#{RESET}" unless outcome
      oc = OUTCOME_COLOR[outcome]
      lit = b.sub(outcome) { "#{RESET}#{oc}#{outcome}#{RESET}#{DIM}" }
      "#{DIM}#{lit}#{RESET}"
    end

    # Quoted speech — coloured green, with names INSIDE still coloured (their
    # reset returns to the quote colour, not full reset) so a name dropped in
    # dialogue still pops as known/novel. That matters: NPC dialogue is exactly
    # where a leaked (yellow) name shows up. Top-level name passes skip inside
    # the quote via the overlap check.
    def collect_quotes!(spans, text, kre)
      text.to_enum(:scan, QUOTE_RE).each do
        m = Regexp.last_match
        spans << [m.begin(0), m.end(0), "#{QUOTE_COLOR}#{colorize_inner(m[0], kre)}#{RESET}"]
      end
    end

    def colorize_inner(quoted, kre)
      inner = []
      collect_named!(inner, quoted, kre, KNOWN_COLOR, tail: QUOTE_COLOR) if kre
      stitch(quoted, inner)
    end

    # Exact known-name matches, skipping anything inside a bracket/quote. `tail`
    # is what follows the coloured name — RESET normally, the surrounding colour
    # when nested inside a quote.
    def collect_named!(spans, text, re, color, tail: RESET)
      text.to_enum(:scan, re).each do
        m = Regexp.last_match
        b, e = m.begin(0), m.end(0)
        next if overlaps?(spans, b, e)
        spans << [b, e, "#{color}#{m[0]}#{tail}"]
      end
    end


    # Splice precomputed replacement strings into the text in order. Overlaps
    # were already prevented at collection time, so this is a plain left-to-
    # right weave. Replacements carry their own ANSI (zero display width), so
    # nothing in the visible string shifts.
    def stitch(text, spans)
      return text if spans.empty?
      spans.sort_by! { |s| s[0] }

      out = +""
      cursor = 0
      spans.each do |st, en, rep|
        next if st < cursor
        out << text[cursor...st] << rep
        cursor = en
      end
      out << text[cursor..]
      out
    end
  end
end
