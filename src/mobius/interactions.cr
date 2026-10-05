require "./pattern_space"

module Mobius
  # A mined pattern: history bytes at a shape's offsets (packed as a key), its
  # next-byte counts by alphabet slot, and its selection score in bits.
  struct MinedPattern
    getter shape : UInt32
    getter key : Int32
    getter support : Int32
    getter score : Float64
    getter counts : Slice(Int32)

    def initialize(@shape : UInt32, @key : Int32, @support : Int32, @score : Float64, @counts : Slice(Int32))
    end
  end

  # Mines patterns of up to `order` specified history positions within `window`
  # bytes before the target and ranks them by the bits they save on the
  # training text over their least-improved parent (the pattern minus one
  # position), less a chance-gain allowance. Matching patterns are combined
  # with a Kneser–Ney prediction through a truncated Möbius (ANOVA) sum.
  #
  # Kneser–Ney with context limit L stands in for every subset of offsets 1..L.
  # For each position the Möbius terms φ(T) are summed over the subsets T of
  # the matching patterns that reach beyond offset L:
  #   log P(x) = log P_KN(x) + Σ φ_x(T) + constant,
  #   φ_x(T) = Σ_{U ⊆ T} (-1)^{|T|-|U|} log P(x | U).
  # For one pattern B this is P_KN(x) · P(x | B) / P(x | B ∩ {1..L}).
  # P(x | U) is Witten–Bell smoothed toward U without its farthest offset,
  # ending in a uniform distribution over 256 bytes.
  #
  # On Tiny Shakespeare this double counts: a pattern's effect is learned
  # against the plain byte frequencies, but Kneser–Ney's context already
  # carries most of it. See ResidualModel.
  class InteractionModel
    getter space : PatternSpace
    getter min_support : Int32
    getter ranked : Array(MinedPattern)
    getter kneser_ney : KneserNey
    getter candidates : Int64

    delegate alphabet, key_at, display, to: @space

    @text : Bytes
    @powers : Array(Int32)
    @unigram : Slice(Int32)
    @tables : Hash(UInt32, Slice(Int32))
    @ranks : Hash(UInt32, Hash(Int32, Int32))

    def initialize(@text : Bytes, window : Int32, order : Int32, @min_support : Int32, context_limit : Int32, capacity : Int32)
      raise ArgumentError.new("minimum support must be at least 1") if @min_support < 1
      @space = PatternSpace.new(@text, window, order, context_limit)
      @powers = (0..order + 1).map { |power| (@space.size.to_i64 ** power).to_i32 }
      @kneser_ney = KneserNey.new(SuffixArray.new(@text), context_limit)
      @unigram = Slice(Int32).new(@space.size, 0)
      @text.each { |byte| @unigram[@space.slot(byte)] += 1 }
      @tables = {} of UInt32 => Slice(Int32)
      @candidates = 0_i64
      @ranked = [] of MinedPattern
      @ranks = {} of UInt32 => Hash(Int32, Int32)
      @space.shapes.each { |shape| @tables[shape] = dense_counts(shape) if @space.popcount(shape) < order }
      @ranked = mine(capacity)
      @ranked.each_with_index do |pattern, rank|
        (@ranks[pattern.shape] ||= {} of Int32 => Int32)[pattern.key] = rank
      end
    end

    # Next-byte counts by slot for the pattern (shape, key) in the training text.
    def counts(shape : UInt32, key : Int32) : Slice(Int32)
      return @unigram if shape == 0
      if @space.popcount(shape) < @space.order
        return @tables[shape][key * @space.size, @space.size]
      end
      @ranked[@ranks[shape][key]].counts
    end

    def base_scores(corpus : Bytes, position : Int32) : Slice(Float64)
      @space.base_scores(@kneser_ney, corpus, position)
    end

    # Shapes of the patterns among the top `active` ranked ones that match the
    # history before `position`.
    def matching(corpus : Bytes, position : Int32, active : Int32) : Array(UInt32)
      result = [] of UInt32
      @ranks.each do |shape, keys|
        key = @space.key_at(corpus, shape, position)
        next if key < 0
        rank = keys[key]?
        result << shape if rank && rank < active
      end
      result
    end

    # Integer weight of each log P(x | U) in the sum of φ(T) over the subsets T
    # of the matching patterns that reach beyond the Kneser–Ney context.
    def coefficients(matching : Array(UInt32)) : Hash(UInt32, Int32)
      terms = Set(UInt32).new
      matching.each { |shape| each_submask(shape) { |term| terms << term if @space.reaches_beyond?(term) } }
      result = Hash(UInt32, Int32).new(0)
      terms.each do |term|
        each_submask(term) do |subset|
          result[subset] += (@space.popcount(term) - @space.popcount(subset)).even? ? 1 : -1
        end
      end
      result
    end

    # Witten–Bell P(x | U) by slot; the last slot is the per-byte probability of
    # any byte outside the alphabet.
    def distribution(corpus : Bytes, position : Int32, shape : UInt32, memo : Hash(UInt32, Slice(Float64))) : Slice(Float64)
      if found = memo[shape]?
        return found
      end
      size = @space.size
      lower = if shape == 0
                Slice(Float64).new(size + 1, 1.0 / 256)
              else
                distribution(corpus, position, shape & ~(1_u32 << (31 - shape.leading_zeros_count)), memo)
              end
      counts = counts(shape, shape == 0 ? 0 : @space.key_at(corpus, shape, position))
      total = counts.sum(0_i64)
      distinct = counts.count(&.> 0)
      result = Slice(Float64).new(size + 1) do |slot|
        observed = slot < size ? counts[slot] : 0
        (observed + distinct * lower[slot]) / (total + distinct)
      end
      memo[shape] = result
    end

    def log_scores(corpus : Bytes, position : Int32, active : Int32, base : Slice(Float64)) : Slice(Float64)
      scores = base.dup
      return scores if active == 0
      memo = {} of UInt32 => Slice(Float64)
      coefficients(matching(corpus, position, active)).each do |shape, weight|
        next if weight == 0
        values = distribution(corpus, position, shape, memo)
        scores.size.times { |slot| scores[slot] += weight * Math.log(values[slot]) }
      end
      scores
    end

    def probability(scores : Slice(Float64), byte : UInt8) : Float64
      @space.probability(scores, byte)
    end

    def probability(corpus : Bytes, position : Int32, active : Int32) : Float64
      probability(log_scores(corpus, position, active, base_scores(corpus, position)), corpus[position])
    end

    # Bits saved on the training text over the least-improved parent, less the
    # chance gain of a pattern with that many distinct next bytes.
    def score(shape : UInt32, key : Int32, counts : Slice(Int32), support : Int32) : Float64
      size = @space.size
      k = @space.popcount(shape)
      best = Float64::INFINITY
      @space.offsets(shape).each_with_index do |offset, digit|
        parent_shape = shape & ~(1_u32 << (offset - 1))
        # digit 0 is the nearest offset, the most significant digit
        weight = @powers[k - 1 - digit]
        parent_key = (key // (weight * size)) * weight + key % weight
        parent = counts(parent_shape, parent_key)
        parent_total = parent.sum(0_i64)
        gain = 0.0
        counts.each_with_index do |count, slot|
          next if count == 0
          gain += count * Math.log2((count.to_f / support) / (parent[slot].to_f / parent_total))
        end
        best = gain if gain < best
      end
      best - (counts.count(&.> 0) - 1) / (2.0 * Math.log(2.0))
    end

    private def each_submask(mask : UInt32, &)
      subset = mask
      loop do
        yield subset
        break if subset == 0
        subset = (subset &- 1) & mask
      end
    end

    private def dense_counts(shape : UInt32) : Slice(Int32)
      size = @space.size
      table = Slice(Int32).new(@powers[@space.popcount(shape) + 1], 0)
      @text.size.times do |position|
        key = @space.key_at(@text, shape, position)
        table[key * size + @space.slot(@text[position])] += 1 if key >= 0
      end
      table
    end

    # Keeps the `capacity` best-scoring patterns with enough support whose shape
    # reaches beyond the Kneser–Ney context.
    private def mine(capacity : Int32) : Array(MinedPattern)
      best = BestScores(MinedPattern).new(capacity)
      size = @space.size
      @space.shapes.each do |shape|
        next unless @space.reaches_beyond?(shape)
        if @space.popcount(shape) < @space.order
          table = @tables[shape]
          (table.size // size).times { |key| consider(best, shape, key, table[key * size, size]) }
        else
          each_sparse_pattern(shape) { |key, counts| consider(best, shape, key, counts) }
        end
      end
      best.sorted
    end

    private def consider(best : BestScores(MinedPattern), shape : UInt32, key : Int32, counts : Slice(Int32)) : Nil
      support = counts.sum
      return if support < @min_support
      @candidates += 1
      score = score(shape, key, counts, support)
      return unless best.admits?(score)
      best.push(MinedPattern.new(shape, key, support, score, @space.popcount(shape) < @space.order ? counts : counts.dup))
    end

    private def each_sparse_pattern(shape : UInt32, &)
      size = @space.size
      keys = Slice(Int32).new(@text.size, 0)
      used = 0
      @text.size.times do |position|
        key = @space.key_at(@text, shape, position)
        next if key < 0
        keys[used] = key * size + @space.slot(@text[position])
        used += 1
      end
      keys = keys[0, used]
      keys.sort!
      counts = Slice(Int32).new(size, 0)
      i = 0
      while i < used
        pattern = keys[i] // size
        counts.fill(0)
        while i < used && keys[i] // size == pattern
          counts[keys[i] % size] += 1
          i += 1
        end
        yield pattern, counts
      end
    end
  end
end
