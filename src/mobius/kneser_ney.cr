require "./suffix_array"

module Mobius
  # The bytes observed after one context, with two counts for each: raw
  # occurrences, and continuation counts (how many distinct bytes precede the
  # context-plus-byte string). Totals and backoff weights use one level's
  # modified Kneser–Ney discounts.
  class KneserNeyLevel
    getter context_length : Int32
    getter bytes : Array(UInt8)
    getter raw : Array(Int32)
    getter continuation : Array(Int32)
    getter raw_total : Int64
    getter continuation_total : Int64
    getter raw_backoff : Float64
    getter continuation_backoff : Float64

    def initialize(@context_length : Int32, @bytes : Array(UInt8), @raw : Array(Int32), @continuation : Array(Int32),
                   @raw_discounts : StaticArray(Float64, 3), @continuation_discounts : StaticArray(Float64, 3))
      @raw_total = @raw.sum(0_i64)
      @continuation_total = @continuation.sum(0_i64)
      @raw_backoff = @raw.sum(0.0) { |count| self.class.discount(count, @raw_discounts) } / @raw_total
      @continuation_backoff = @continuation.sum(0.0) { |count| self.class.discount(count, @continuation_discounts) } / @continuation_total
    end

    def self.discount(count : Int32, discounts : StaticArray(Float64, 3)) : Float64
      return 0.0 if count <= 0
      count >= 3 ? discounts[2] : discounts[count - 1]
    end

    def raw_count(byte : UInt8) : Int32
      (slot = @bytes.index(byte)) ? @raw[slot] : 0
    end

    def continuation_count(byte : UInt8) : Int32
      (slot = @bytes.index(byte)) ? @continuation[slot] : 0
    end

    # This level's discounted share of `byte`, before adding backoff mass.
    def raw_term(byte : UInt8) : Float64
      count = raw_count(byte)
      (count - self.class.discount(count, @raw_discounts)) / @raw_total
    end

    def continuation_term(byte : UInt8) : Float64
      count = continuation_count(byte)
      (count - self.class.discount(count, @continuation_discounts)) / @continuation_total
    end
  end

  # Interpolated modified Kneser–Ney over contiguous contexts (Chen and
  # Goodman, 1998). Under a context limit L, a context of exactly L bytes uses
  # raw counts and every shorter one uses continuation counts. Discounts come
  # from count-of-counts in the training text. The final fallback is uniform
  # over all 256 byte values.
  class KneserNey
    VOCABULARY = 256
    START      = 256 # stands in for the missing byte before the text
    CACHE_RUN  =  64 # cache levels for contexts at least this frequent

    getter suffixes : SuffixArray
    getter max_context : Int32
    getter raw_discounts : Array(StaticArray(Float64, 3))
    getter continuation_discounts : Array(StaticArray(Float64, 3))

    def initialize(@suffixes : SuffixArray, @max_context : Int32)
      raise ArgumentError.new("context limit must be at least 0") if @max_context < 0
      @raw_discounts = [] of StaticArray(Float64, 3)
      @continuation_discounts = [] of StaticArray(Float64, 3)
      @cache = {} of String => KneserNeyLevel?
      compute_discounts
    end

    # Chen and Goodman's estimates from the numbers of strings seen exactly
    # once to four times, kept within (0, count] so every level leaves some mass
    # for backoff.
    def self.discounts(n : StaticArray(Int64, 5)) : StaticArray(Float64, 3)
      y = n[1] + 2 * n[2] > 0 ? n[1] / (n[1] + 2 * n[2]) : 0.5
      d1 = n[1] > 0 ? 1.0 - 2.0 * y * n[2] / n[1] : 0.5
      d2 = n[2] > 0 ? 2.0 - 3.0 * y * n[3] / n[2] : 1.0
      d3 = n[3] > 0 ? 3.0 - 4.0 * y * n[4] / n[3] : 1.5
      StaticArray[d1.clamp(0.01, 1.0), d2.clamp(0.01, 2.0), d3.clamp(0.01, 3.0)]
    end

    # Levels for the history's suffixes of length 0, 1, ... up to the limit,
    # stopping at the first context never followed by a byte in training.
    def levels(history : Bytes, limit : Int32 = @max_context) : Array(KneserNeyLevel)
      result = [] of KneserNeyLevel
      0.upto(Math.min(limit, history.size)) do |k|
        level = level(history[history.size - k, k])
        break unless level
        result << level
      end
      result
    end

    # Probability of `byte` under every context limit 0..max_context.
    def probabilities(levels : Array(KneserNeyLevel), byte : UInt8) : Array(Float64)
      # chain[k]: continuation-count interpolation through level k.
      chain = Array(Float64).new(levels.size)
      lower = 1.0 / VOCABULARY
      levels.each do |level|
        lower = level.continuation_term(byte) + level.continuation_backoff * lower
        chain << lower
      end
      Array(Float64).new(@max_context + 1) do |limit|
        if limit < levels.size
          below = limit == 0 ? 1.0 / VOCABULARY : chain[limit - 1]
          levels[limit].raw_term(byte) + levels[limit].raw_backoff * below
        else
          chain.last? || 1.0 / VOCABULARY
        end
      end
    end

    def probability(history : Bytes, byte : UInt8, limit : Int32 = @max_context) : Float64
      raise ArgumentError.new("context limit exceeds #{@max_context}") if limit > @max_context
      probabilities(levels(history, limit), byte)[limit]
    end

    # Mean bits per byte for corpus[start...finish), predicting each byte from
    # every byte before it. Returns one value per context limit 0..max_context.
    def bits_per_byte(corpus : Bytes, start : Int32, finish : Int32) : Array(Float64)
      raise ArgumentError.new("empty evaluation range") unless 0 <= start < finish <= corpus.size
      sums = Array(Float64).new(@max_context + 1, 0.0)
      (start...finish).each do |position|
        levels = levels(corpus[0, position])
        probabilities(levels, corpus[position]).each_with_index do |p, limit|
          sums[limit] -= Math.log2(p)
        end
      end
      sums.map { |sum| sum / (finish - start) }
    end

    def level(context : Bytes) : KneserNeyLevel?
      first, last = @suffixes.run(context)
      return nil if first == last
      return build_level(context.size, first, last) if last - first < CACHE_RUN
      key = String.new(context)
      return @cache[key] if @cache.has_key?(key)
      @cache[key] = build_level(context.size, first, last)
    end

    # Suffixes in a context's run are sorted by the byte that follows the
    # context, so each next byte occupies one block of the run.
    private def build_level(k : Int32, first : Int32, last : Int32) : KneserNeyLevel?
      text = @suffixes.text
      order = @suffixes.order
      bytes = [] of UInt8
      raw = [] of Int32
      continuation = [] of Int32
      seen = Slice(UInt64).new(5, 0_u64)
      current = -1
      (first...last).each do |i|
        start = order[i]
        next if start + k >= text.size
        byte = text[start + k].to_i
        if byte != current
          bytes << byte.to_u8
          raw << 0
          continuation << 0
          seen.fill(0_u64)
          current = byte
        end
        raw[-1] += 1
        continuation[-1] += 1 if mark_predecessor(seen, start)
      end
      return nil if bytes.empty?
      KneserNeyLevel.new(k, bytes, raw, continuation, @raw_discounts[k], @continuation_discounts[k])
    end

    # Records the byte before `start` (or the start of text) in `seen`; returns
    # whether it is new.
    private def mark_predecessor(seen : Slice(UInt64), start : Int32) : Bool
      previous = start > 0 ? @suffixes.text[start - 1].to_i : START
      bit = 1_u64 << (previous % 64)
      return false if seen[previous // 64] & bit != 0
      seen[previous // 64] |= bit
      true
    end

    # For each level k, count how many distinct (k + 1)-byte strings occur
    # r = 1..4 times (raw) or after r distinct bytes (continuation).
    private def compute_discounts : Nil
      text = @suffixes.text
      order = @suffixes.order
      lcp = @suffixes.lcp
      n = text.size
      seen = Slice(UInt64).new(5, 0_u64)
      0.upto(@max_context) do |k|
        length = k + 1
        raw_n = StaticArray(Int64, 5).new(0_i64)
        continuation_n = StaticArray(Int64, 5).new(0_i64)
        i = 0
        while i < n
          if n - order[i] < length
            i += 1
            next
          end
          j = i + 1
          while j < n && lcp[j] >= length
            j += 1
          end
          seen.fill(0_u64)
          distinct = 0
          (i...j).each { |s| distinct += 1 if mark_predecessor(seen, order[s]) }
          raw_n[j - i] += 1 if j - i <= 4
          continuation_n[distinct] += 1 if distinct <= 4
          i = j
        end
        @raw_discounts << self.class.discounts(raw_n)
        @continuation_discounts << self.class.discounts(continuation_n)
      end
    end
  end
end
