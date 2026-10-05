require "./lattice_search"

module Mobius
  # A pattern with the posterior probability that refinement stops there for
  # the current history.
  struct SufficientPattern
    getter shape : UInt32
    getter support : Int32
    getter counts : Slice(Int32)
    getter weight : Float64

    def initialize(@shape : UInt32, @support : Int32, @counts : Slice(Int32), @weight : Float64)
    end
  end

  # Predicts the next byte by asking, from the empty pattern outward, whether
  # the history's own byte at another offset changes what follows. This is
  # Context Tree Weighting carried from suffixes to the masked lattice and
  # restricted to the current history.
  #
  # The models are refinement paths. At pattern S, whose matches are D_S, a
  # model either stops and predicts from D_S, or refines by an offset o whose
  # pattern S ∪ {o} has enough support: the matches that agree with the
  # history at o go on down the path, and those that disagree are explained by
  # an estimate of their own. The prior stops with probability `stop` and
  # otherwise picks one of the supported refinements uniformly; a pattern with
  # none always stops. Every estimate uses a Dirichlet prior with mean P_0
  # (the training byte frequencies) and β = `concentration` pseudo-counts:
  #   P(D) = Γ(β) / Γ(n + β) · Π_x Γ(c_x + β·P_0(x)) / Γ(β·P_0(x)),
  #   P(x | D) = (c_x + β·P_0(x)) / (n + β).
  # Refining by o wins when the agreeing and disagreeing matches continue
  # differently; when they continue alike, the cost of the extra estimate
  # keeps the weight at S. A pattern's weight is the posterior probability
  # that the path ends there, and the prediction is the weight-averaged
  # estimate, with a 1e-6 floor spread over all 256 bytes. Weighted
  # probabilities are computed from the most specific patterns up to the
  # empty one, then path probabilities back down, so each pattern is handled
  # once. With `suffixes_only`, a pattern may only be refined by the next
  # older offset, so the patterns are the contiguous suffixes and the method
  # is Context Tree Weighting along the current context.
  class SufficiencyPredictor
    FLOOR = 1e-6

    getter search : LatticeSearch
    getter min_support : Int32
    getter concentration : Float64
    getter stop : Float64
    getter? suffixes_only : Bool

    delegate alphabet, unigram, display, window, to: @search

    @prior_log_gamma : Slice(Float64)
    @log_gamma_concentration : Float64

    def initialize(index : Index, window : Int32, @min_support : Int32, @concentration : Float64, @stop : Float64 = 0.5,
                   @suffixes_only : Bool = false)
      raise ArgumentError.new("minimum support must be at least 1") if @min_support < 1
      raise ArgumentError.new("concentration must be positive") unless @concentration > 0
      raise ArgumentError.new("stop probability must be between 0 and 1") unless 0 < @stop < 1
      @search = LatticeSearch.new(index, window)
      @prior_log_gamma = Slice(Float64).new(alphabet.size) { |slot| Math.lgamma(@concentration * unigram[slot]) }
      @log_gamma_concentration = Math.lgamma(@concentration)
    end

    # Natural-log probability of next-byte counts under the Dirichlet prior,
    # in any order.
    def log_evidence(counts : Slice(Int32), support : Int32) : Float64
      return 0.0 if support == 0
      total = @log_gamma_concentration - Math.lgamma(support + @concentration)
      counts.each_with_index do |count, slot|
        next if count == 0
        total += Math.lgamma(count + @concentration * unigram[slot]) - @prior_log_gamma[slot]
      end
      total
    end

    # Patterns with positive weight, heaviest first; the weights sum to 1.
    def patterns(history : Bytes) : Array(SufficientPattern)
      shapes = [] of UInt32
      supports = [] of Int32
      counts = [] of Slice(Int32)
      found = {} of UInt32 => Int32
      @search.each(history, @min_support) do |shape, support, next_counts|
        found[shape] = shapes.size
        shapes << shape
        supports << support
        counts << next_counts
        !@suffixes_only || suffix?(shape)
      end
      size = shapes.size
      limit = Math.min(window, history.size)
      children = Array.new(size) do |i|
        offsets = if @suffixes_only
                    suffix?(shapes[i]) && shapes[i].popcount < limit ? [shapes[i].popcount.to_i + 1] : [] of Int32
                  else
                    (1..limit).to_a
                  end
        offsets.compact_map do |offset|
          bit = 1_u32 << (offset - 1)
          found[shapes[i] | bit]? if shapes[i] & bit == 0
        end
      end

      # From the most specific patterns up: log weighted probability of each
      # pattern's matches, and the posterior shares of stopping or refining.
      order = (0...size).to_a.sort_by { |i| -shapes[i].popcount }
      weighted = Array(Float64).new(size, 0.0)
      stop_share = Array(Float64).new(size, 1.0)
      refine_shares = Array(Array(Float64)).new(size) { [] of Float64 }
      order.each do |i|
        evidence = log_evidence(counts[i], supports[i])
        if children[i].empty?
          weighted[i] = evidence
          next
        end
        stop_term = Math.log(@stop) + evidence
        refine_prior = Math.log(1 - @stop) - Math.log(children[i].size)
        terms = children[i].map do |child|
          rest = Slice(Int32).new(alphabet.size) { |slot| counts[i][slot] - counts[child][slot] }
          refine_prior + log_evidence(rest, supports[i] - supports[child]) + weighted[child]
        end
        top = Math.max(stop_term, terms.max)
        total = top + Math.log(Math.exp(stop_term - top) + terms.sum { |term| Math.exp(term - top) })
        weighted[i] = total
        stop_share[i] = Math.exp(stop_term - total)
        refine_shares[i] = terms.map { |term| Math.exp(term - total) }
      end

      # From the empty pattern down: probability that the path reaches each
      # pattern, then that it stops there.
      reach = Array(Float64).new(size, 0.0)
      reach[found[0_u32]] = 1.0
      order.reverse_each do |i|
        next if reach[i] == 0.0
        children[i].each_with_index { |child, j| reach[child] += reach[i] * refine_shares[i][j] }
      end
      (0...size).compact_map do |i|
        weight = reach[i] * stop_share[i]
        SufficientPattern.new(shapes[i], supports[i], counts[i], weight) if weight > 0
      end.sort_by { |pattern| {-pattern.weight, pattern.shape} }
    end

    # Whether the shape is the offsets 1..k for some k.
    def suffix?(shape : UInt32) : Bool
      shape & (shape &+ 1) == 0
    end

    # Posterior mean estimate of one pattern, by alphabet slot.
    def estimate_at(pattern : SufficientPattern, slot : Int32) : Float64
      (pattern.counts[slot] + @concentration * unigram[slot]) / (pattern.support + @concentration)
    end

    def distribution(patterns : Array(SufficientPattern)) : Slice(Float64)
      total = patterns.sum(&.weight)
      result = Slice(Float64).new(256, FLOOR / 256)
      patterns.each do |pattern|
        share = (1 - FLOOR) * pattern.weight / total
        alphabet.each_with_index { |byte, slot| result[byte] += share * estimate_at(pattern, slot) }
      end
      result
    end

    def probability(patterns : Array(SufficientPattern), byte : UInt8) : Float64
      slot = @search.slot(byte)
      return FLOOR / 256 if slot < 0
      total = patterns.sum(&.weight)
      (1 - FLOOR) * patterns.sum { |pattern| pattern.weight * estimate_at(pattern, slot) } / total + FLOOR / 256
    end
  end
end
