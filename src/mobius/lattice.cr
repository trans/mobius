require "./lattice_search"

module Mobius
  # A masked pattern consistent with the current history: which offsets it
  # specifies (bit o - 1 for offset o; 0 is the empty pattern), how often it
  # occurs, what followed it (by alphabet slot), and the leave-one-out bits
  # per match that set its weight.
  struct LatticePattern
    getter shape : UInt32
    getter support : Int32
    getter counts : Slice(Int32)
    getter bits : Float64

    def initialize(@shape : UInt32, @support : Int32, @counts : Slice(Int32), @bits : Float64)
    end

    def weight : Float64
      2.0 ** -@bits
    end
  end

  # Predicts the next byte from the masked patterns that match the last
  # `window` bytes of history, with exact counts from a bit-plane index over
  # the training text. Nothing is fitted.
  #
  # Each subset S of the offsets 1..window defines a pattern: the history's
  # bytes at those offsets. Its matches are training positions preceded by
  # the same bytes at the same offsets, and the bytes at those positions give
  # counts c_S (n_S matches, d_S distinct bytes). A pattern predicts with
  # Witten–Bell smoothing toward the training unigram P_0:
  #   P_S(x) = (c_S(x) + d_S · P_0(x)) / (n_S + d_S).
  # Its weight is how well that estimator predicts its own matches, each left
  # out in turn: w_S = 2^(-h_S), where h_S is the mean leave-one-out bits per
  # match (a single match is predicted by P_0). The prediction is the
  # weight-proportional average of the `capacity` highest-weight patterns with
  # at least `min_support` matches; patterns with identical counts are kept
  # once. The search adds offsets in increasing order, stops where support
  # falls below the minimum (it never grows as offsets are added), and skips
  # branches whose best attainable weight, (n - 1 + max P_0) / n for support n,
  # cannot enter the kept set. A floor of 1e-6 spread over all 256 bytes keeps
  # every probability positive.
  class LatticePredictor
    FLOOR = 1e-6

    getter search : LatticeSearch
    getter min_support : Int32
    getter capacity : Int32

    delegate alphabet, unigram, display, window, to: @search

    @best_unigram : Float64
    @kept : Array(LatticePattern)
    @keys : Set(UInt64)

    def initialize(index : Index, window : Int32, @min_support : Int32, @capacity : Int32)
      raise ArgumentError.new("minimum support must be at least 1") if @min_support < 1
      raise ArgumentError.new("capacity must be at least 1") if @capacity < 1
      @search = LatticeSearch.new(index, window)
      @best_unigram = @search.unigram.max
      @kept = [] of LatticePattern
      @keys = Set(UInt64).new
    end

    # The kept patterns for the history, highest weight first.
    def patterns(history : Bytes) : Array(LatticePattern)
      @kept = [] of LatticePattern
      @keys = Set(UInt64).new
      @search.each(history, @min_support) do |shape, support, counts, _|
        offer(shape, support, counts)
        shape == 0 || @kept.size < @capacity || attainable(support) > @kept.last.weight
      end
      @kept
    end

    # Witten–Bell estimate of one pattern, by alphabet slot.
    def estimate(pattern : LatticePattern) : Slice(Float64)
      Slice(Float64).new(alphabet.size) { |slot| estimate_at(pattern, slot) }
    end

    # Weight-averaged prediction of the first `limit` patterns, over all bytes.
    def distribution(patterns : Array(LatticePattern), limit : Int32 = patterns.size) : Slice(Float64)
      used = patterns.first(limit)
      total = used.sum(&.weight)
      result = Slice(Float64).new(256, FLOOR / 256)
      used.each do |pattern|
        share = (1 - FLOOR) * pattern.weight / total
        estimate(pattern).each_with_index { |p, slot| result[alphabet[slot]] += share * p }
      end
      result
    end

    def probability(patterns : Array(LatticePattern), byte : UInt8, limit : Int32 = patterns.size) : Float64
      used = patterns.first(limit)
      total = used.sum(&.weight)
      slot = @search.slot(byte)
      mixed = slot < 0 ? 0.0 : used.sum { |pattern| pattern.weight * estimate_at(pattern, slot) } / total
      (1 - FLOOR) * mixed + FLOOR / 256
    end

    # Mean leave-one-out bits per match of a pattern's Witten–Bell estimate.
    def leave_one_out_bits(counts : Slice(Int32), support : Int32) : Float64
      if support == 1
        return -Math.log2(unigram[counts.index(&.> 0).not_nil!])
      end
      distinct = counts.count(&.> 0)
      total = 0.0
      counts.each_with_index do |count, slot|
        next if count == 0
        others = distinct - (count == 1 ? 1 : 0)
        total -= count * Math.log2((count - 1 + others * unigram[slot]) / (support - 1 + others))
      end
      total / support
    end

    # The best weight any pattern with at most `support` matches can reach:
    # every match followed by the most common byte.
    def attainable(support : Int32) : Float64
      support >= 2 ? (support - 1 + @best_unigram) / support : @best_unigram
    end

    private def estimate_at(pattern : LatticePattern, slot : Int32) : Float64
      distinct = pattern.counts.count(&.> 0)
      (pattern.counts[slot] + distinct * unigram[slot]) / (pattern.support + distinct)
    end

    private def offer(shape : UInt32, support : Int32, counts : Slice(Int32)) : Nil
      key = key_for(counts, support)
      return if @keys.includes?(key)
      pattern = LatticePattern.new(shape, support, counts, leave_one_out_bits(counts, support))
      return if @kept.size >= @capacity && pattern.weight <= @kept.last.weight
      if @kept.size >= @capacity
        evicted = @kept.pop
        @keys.delete(key_for(evicted.counts, evicted.support))
      end
      index = @kept.index { |kept| kept.weight < pattern.weight } || @kept.size
      @kept.insert(index, pattern)
      @keys << key
    end

    # Patterns with identical counts almost always have identical matches.
    private def key_for(counts : Slice(Int32), support : Int32) : UInt64
      counts.each_with_index.reduce(support.to_u64) do |hash, (count, slot)|
        (hash &* 1_000_003_u64) &+ (count.to_u64 &* 31_u64 &+ slot.to_u64)
      end
    end
  end
end
