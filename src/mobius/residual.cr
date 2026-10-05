require "./pattern_space"

module Mobius
  # A pattern kept by the residual miner, with its natural-log correction for
  # each score slot.
  struct ResidualPattern
    getter shape : UInt32
    getter key : Int32
    getter support : Int32
    getter score : Float64
    getter log_ratios : Slice(Float64)
    # Identifies the set of training positions the pattern matches.
    getter fingerprint : UInt64

    def initialize(@shape : UInt32, @key : Int32, @support : Int32, @score : Float64, @log_ratios : Slice(Float64), @fingerprint : UInt64)
    end
  end

  # Corrects Kneser–Ney with mined patterns of up to `order` history positions
  # that reach beyond its context. Each pattern is judged by what Kneser–Ney
  # gets wrong at its training matches: the next bytes that actually followed
  # are compared with the bytes Kneser–Ney expected there. Kneser–Ney is
  # cross-fitted for this, so it never predicts text it was trained on: each
  # training position belongs to one of `folds` folds and is predicted by a
  # model trained on the other folds joined end to end. Folds are contiguous
  # blocks, or with `interleave` > 0, blocks of that many bytes dealt to the
  # folds in turn, so every fold's model has seen every part of the text.
  #
  # With actual counts a_x and expected counts e_x at the matches, the
  # correction is r_x = (a_x + 1) / (e_x + 1): near 1 when Kneser–Ney expected
  # little and nothing was seen, and near a_x / e_x when counts are large. A
  # pattern's score is the bits Σ a_x log2 r_x it saves at its training
  # matches, less the chance gain (d - 1) / (2 ln 2) for d distinct actual
  # bytes. Of patterns that match exactly the same positions, only the first
  # ranked is kept. To predict, Kneser–Ney trained on all the text is
  # multiplied by the ratios of the matching kept patterns (all of them, or
  # only the best-ranked one) and renormalized.
  class ResidualModel
    getter space : PatternSpace
    getter min_support : Int32
    getter folds : Int32
    getter interleave : Int32
    getter kneser_ney : KneserNey
    getter ranked : Array(ResidualPattern)
    getter candidates : Int64
    # Cross-fitted Kneser–Ney probability of each slot at each training
    # position: index position * alphabet size + slot.
    getter expected : Slice(Float32)

    delegate alphabet, key_at, display, to: @space

    @text : Bytes
    @ranks : Hash(UInt32, Hash(Int32, Int32))

    def initialize(@text : Bytes, window : Int32, order : Int32, @min_support : Int32, context_limit : Int32,
                   @folds : Int32, @interleave : Int32, capacity : Int32)
      raise ArgumentError.new("minimum support must be at least 1") if @min_support < 1
      raise ArgumentError.new("folds must be 2 to the text size") unless 2 <= @folds <= @text.size
      raise ArgumentError.new("interleave must be at least 0") if @interleave < 0
      @space = PatternSpace.new(@text, window, order, context_limit)
      @kneser_ney = KneserNey.new(SuffixArray.new(@text), context_limit)
      @candidates = 0_i64
      @ranked = [] of ResidualPattern
      @ranks = {} of UInt32 => Hash(Int32, Int32)
      @expected = Slice(Float32).new(0)
      @expected = cross_fitted_expectations
      @ranked = mine(capacity)
      @ranked.each_with_index do |pattern, rank|
        (@ranks[pattern.shape] ||= {} of Int32 => Int32)[pattern.key] = rank
      end
    end

    def fold_of(position : Int32) : Int32
      return (position // @interleave) % @folds if @interleave > 0
      ((position.to_i64 * @folds) // @text.size).to_i32
    end

    def base_scores(corpus : Bytes, position : Int32) : Slice(Float64)
      @space.base_scores(@kneser_ney, corpus, position)
    end

    # Ranks, best first, of the top `active` kept patterns that match the
    # history before `position`.
    def matching(corpus : Bytes, position : Int32, active : Int32) : Array(Int32)
      result = [] of Int32
      @ranks.each do |shape, keys|
        key = @space.key_at(corpus, shape, position)
        next if key < 0
        rank = keys[key]?
        result << rank if rank && rank < active
      end
      result.sort!
    end

    def log_scores(corpus : Bytes, position : Int32, active : Int32, best_only : Bool, base : Slice(Float64)) : Slice(Float64)
      log_scores(matching(corpus, position, active), best_only, base)
    end

    # Applies the patterns with these ranks (best first) to the base scores.
    def log_scores(ranks : Array(Int32), best_only : Bool, base : Slice(Float64)) : Slice(Float64)
      scores = base.dup
      ranks = ranks.first(1) if best_only
      ranks.each do |rank|
        ratios = @ranked[rank].log_ratios
        scores.size.times { |slot| scores[slot] += ratios[slot] }
      end
      scores
    end

    def probability(scores : Slice(Float64), byte : UInt8) : Float64
      @space.probability(scores, byte)
    end

    private def cross_fitted_expectations : Slice(Float32)
      n = @text.size
      size = @space.size
      result = Slice(Float32).new(n * size, 0_f32)
      @folds.times do |fold|
        rest = Bytes.new(n - (0...n).count { |position| fold_of(position) == fold })
        used = 0
        n.times do |position|
          next if fold_of(position) == fold
          rest[used] = @text[position]
          used += 1
        end
        model = KneserNey.new(SuffixArray.new(rest), @space.context_limit)
        n.times do |position|
          next unless fold_of(position) == fold
          distribution = model.distribution(model.levels(@text[0, position]), @space.context_limit)
          size.times { |slot| result[position * size + slot] = distribution[@space.alphabet[slot]].to_f32 }
        end
      end
      result
    end

    # Groups training positions by pattern, one shape at a time, and keeps the
    # `capacity` best-scoring patterns with enough support.
    private def mine(capacity : Int32) : Array(ResidualPattern)
      best = BestScores(ResidualPattern).new(capacity)
      entries = Slice(Int64).new(@text.size, 0_i64)
      counts = Slice(Int32).new(@space.size, 0)
      sums = Slice(Float64).new(@space.size, 0.0)
      @space.shapes.each do |shape|
        next unless @space.reaches_beyond?(shape)
        used = 0
        @text.size.times do |position|
          key = @space.key_at(@text, shape, position)
          next if key < 0
          entries[used] = (key.to_i64 << 32) | position
          used += 1
        end
        grouped = entries[0, used]
        grouped.sort!
        i = 0
        while i < used
          key = grouped[i] >> 32
          j = i
          while j < used && grouped[j] >> 32 == key
            j += 1
          end
          consider(best, shape, key.to_i32, grouped[i, j - i], counts, sums) if j - i >= @min_support
          i = j
        end
      end
      seen = Set(UInt64).new
      best.sorted.select { |pattern| seen.add?(pattern.fingerprint) }
    end

    # SplitMix64 finalizer; summing it over positions fingerprints a match set.
    private def mix(value : UInt64) : UInt64
      z = value &+ 0x9E3779B97F4A7C15_u64
      z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9_u64
      z = (z ^ (z >> 27)) &* 0x94D049BB133111EB_u64
      z ^ (z >> 31)
    end

    private def consider(best : BestScores(ResidualPattern), shape : UInt32, key : Int32, members : Slice(Int64),
                         counts : Slice(Int32), sums : Slice(Float64)) : Nil
      @candidates += 1
      size = @space.size
      support = members.size
      members.each { |member| counts[@space.slot(@text[member & 0xFFFFFFFF])] += 1 }
      observed = (0...size).select { |slot| counts[slot] > 0 }
      members.each do |member|
        row = (member & 0xFFFFFFFF) * size
        observed.each { |slot| sums[slot] += @expected[row + slot] }
      end
      score = -(observed.size - 1) / (2.0 * Math.log(2.0))
      observed.each { |slot| score += counts[slot] * Math.log2((counts[slot] + 1) / (sums[slot] + 1)) }
      if best.admits?(score)
        expected = Slice(Float64).new(size, 0.0)
        fingerprint = 0_u64
        members.each do |member|
          position = member & 0xFFFFFFFF
          row = position * size
          size.times { |slot| expected[slot] += @expected[row + slot] }
          fingerprint &+= mix(position.to_u64)
        end
        # Bytes outside the alphabet were never seen or expected: ratio 1.
        ratios = Slice(Float64).new(size + 1, 0.0)
        size.times { |slot| ratios[slot] = Math.log((counts[slot] + 1) / (expected[slot] + 1)) }
        best.push(ResidualPattern.new(shape, key, support, score, ratios, fingerprint))
      end
      observed.each do |slot|
        counts[slot] = 0
        sums[slot] = 0.0
      end
    end
  end
end
