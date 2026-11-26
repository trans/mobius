module Mobius
  # Next-byte counts after each context of 0 to `max_context` bytes, over the
  # predicted bytes in the last `span` positions before the current one. A
  # context may reach back before the span; only the byte it predicts must lie
  # inside it. Contexts pack exactly into 56 bits, so max_context is at most 7.
  class RecencyCache
    MAX_CONTEXT = 7

    getter span : Int32
    getter max_context : Int32
    getter position : Int32

    @corpus : Bytes
    @low : Int32
    @pairs : Array(Hash(UInt64, Int32))
    @totals : Array(Hash(UInt64, Int32))
    @distinct : Array(Hash(UInt64, Int32))

    def initialize(@corpus : Bytes, @span : Int32, @max_context : Int32, start : Int32)
      raise ArgumentError.new("span must be at least 1") if @span < 1
      raise ArgumentError.new("cache context must be 0 to #{MAX_CONTEXT}") unless 0 <= @max_context <= MAX_CONTEXT
      raise ArgumentError.new("start is outside the corpus") unless 0 <= start <= @corpus.size
      @pairs = Array.new(@max_context + 1) { {} of UInt64 => Int32 }
      @totals = Array.new(@max_context + 1) { {} of UInt64 => Int32 }
      @distinct = Array.new(@max_context + 1) { {} of UInt64 => Int32 }
      @low = Math.max(0, start - @span)
      @position = @low
      advance(start)
    end

    # Slides the window so it holds the `span` predicted bytes before `position`.
    def advance(position : Int32) : Nil
      raise ArgumentError.new("the cache only moves forward") if position < @position
      while @position < position
        update(@position, 1)
        @position += 1
      end
      while @low < @position - @span
        update(@low, -1)
        @low += 1
      end
    end

    # For the k-byte context before the current position: how often `byte`
    # followed it in the window, how often anything did, and how many
    # distinct bytes did.
    def counts(k : Int32, byte : UInt8) : Tuple(Int32, Int32, Int32)
      return {0, 0, 0} if k > @position
      context = pack(@position, k)
      {@pairs[k][(context << 8) | byte]? || 0, @totals[k][context]? || 0, @distinct[k][context]? || 0}
    end

    # The longest context before the current position that occurs in the
    # window, or -1 when the window is empty.
    def longest : Int32
      k = -1
      while k < @max_context && k + 1 <= @position && (@totals[k + 1][pack(@position, k + 1)]? || 0) > 0
        k += 1
      end
      k
    end

    # Witten–Bell interpolation from the empty context up to the longest one
    # in the window, ending in a uniform distribution over 256 bytes.
    def probability(byte : UInt8) : Float64
      p = 1.0 / 256
      0.upto(longest) do |k|
        count, total, distinct = counts(k, byte)
        p = (count + distinct * p) / (total + distinct)
      end
      p
    end

    private def pack(position : Int32, k : Int32) : UInt64
      key = 0_u64
      (position - k).upto(position - 1) { |i| key = (key << 8) | @corpus[i] }
      key
    end

    private def update(target : Int32, delta : Int32) : Nil
      byte = @corpus[target]
      0.upto(Math.min(@max_context, target)) do |k|
        context = pack(target, k)
        pair = (context << 8) | byte
        before = @pairs[k][pair]? || 0
        after = before + delta
        after == 0 ? @pairs[k].delete(pair) : (@pairs[k][pair] = after)
        total = (@totals[k][context]? || 0) + delta
        total == 0 ? @totals[k].delete(context) : (@totals[k][context] = total)
        change = before == 0 ? 1 : (after == 0 ? -1 : 0)
        next if change == 0
        distinct = (@distinct[k][context]? || 0) + change
        distinct == 0 ? @distinct[k].delete(context) : (@distinct[k][context] = distinct)
      end
    end
  end

  # Mixes Kneser–Ney with a recency cache: P = (1 - λ_b) P_KN + λ_b P_cache,
  # with one weight per bucket b (the longest cached context, shifted by 1).
  module RecencyMixture
    # EM for the weights that maximize the likelihood of the observed bytes,
    # given each byte's Kneser–Ney and cache probabilities and its bucket.
    def self.fit(kneser_ney : Array(Float64), cache : Array(Float64), buckets : Array(Int32), count : Int32, rounds : Int32 = 300) : Array(Float64)
      weights = Array(Float64).new(count, 0.1)
      rounds.times do
        responsibility = Array(Float64).new(count, 0.0)
        sizes = Array(Int32).new(count, 0)
        kneser_ney.each_index do |i|
          bucket = buckets[i]
          from_cache = weights[bucket] * cache[i]
          responsibility[bucket] += from_cache / (from_cache + (1 - weights[bucket]) * kneser_ney[i])
          sizes[bucket] += 1
        end
        weights = Array(Float64).new(count) { |b| sizes[b] > 0 ? responsibility[b] / sizes[b] : 0.0 }
      end
      weights
    end

    def self.probability(kneser_ney : Float64, cache : Float64, weight : Float64) : Float64
      (1 - weight) * kneser_ney + weight * cache
    end
  end
end
