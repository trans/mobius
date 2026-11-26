require "./lattice_search"

module Mobius
  # A pattern with the posterior probability that refinement stops there for
  # the current history, and its next-byte estimate by alphabet slot.
  struct SufficientPattern
    getter shape : UInt32
    getter support : Int32
    getter counts : Slice(Int32)
    getter weight : Float64
    getter estimate : Slice(Float64)

    def initialize(@shape : UInt32, @support : Int32, @counts : Slice(Int32), @weight : Float64, @estimate : Slice(Float64))
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
  # older offset, so the patterns are the contiguous suffixes, as in Context
  # Tree Weighting along the current context (though CTW splits a context's
  # data among all its children, not into agreeing and disagreeing halves).
  #
  # With `hierarchical`, priors are centered on the parent pattern, S without
  # its farthest offset, instead of P_0: P̂_S = (c_S + β·P̂_parent(S)) /
  # (n_S + β), with P̂_∅ centered on P_0. Stopping at S, and the matches that
  # disagree when S is refined, use a Dirichlet centered on P̂_parent(S); a
  # refined pattern uses its own parent's estimate. A refinement then costs
  # bits only in proportion to how much it differs from where it came from.
  #
  # With a `chain_strength` β_c as well, a parent's estimate is built from
  # continuation counts, as in Kneser–Ney: for a child that adds offset g, the
  # parent's count for x is how many distinct bytes occur g places before its
  # matches followed by x. Q_∅ = P_0; a pattern P serving a child that adds
  # offset g has Q = (N_g + β_c·mean(P)) / (ΣN_g + β_c), and the child's mean is
  # that Q. Leaf estimates and evidence keep raw counts and strength β.
  #
  # With a `nearest_prior` p, refining is not uniform over offsets: the
  # nearest offset the pattern does not yet fix gets probability p and the
  # other offsets share 1 − p. Probability given to a refinement without
  # enough support goes to stopping. With p = 1 the model is exactly the
  # suffix model.
  #
  # With `folds` K, evidence is cross-validated instead of a marginal
  # likelihood (a pseudo-Bayes factor): the training text is cut into K
  # contiguous blocks, and each block's matches are predicted from the other
  # blocks' counts with the same prior mean,
  #   Σ_f Σ_x c_f(x) · log[(c(x) − c_f(x) + β·m_x) / (n − n_f + β)].
  # Prior means stay computed from all the text.
  #
  # With a `discount` D, every estimate is a Pitman–Yor posterior with one
  # table per distinct byte, strength θ = `concentration` and the same prior
  # mean m: P̂(x) = (max(c_x − D, 0) + (θ + D·d)·m_x) / (θ + n) for d distinct
  # bytes, which with θ = 0 is interpolated absolute discounting. Evidence is
  # the probability of the counts with one table per distinct byte (the
  # seating under which a Pitman–Yor hierarchy reproduces Kneser–Ney):
  #   log P(D) = Σ_seen log m_x + Σ_{j=1}^{d−1} log(θ + jD)
  #              − log Γ(θ + n) + log Γ(θ + 1) + Σ_x [log Γ(c_x − D) − log Γ(1 − D)].
  class SufficiencyPredictor
    FLOOR = 1e-6

    getter search : LatticeSearch
    getter min_support : Int32
    getter concentration : Float64
    getter stop : Float64
    getter? suffixes_only : Bool
    getter? hierarchical : Bool
    getter discount : Float64?
    getter chain_strength : Float64?
    getter nearest_prior : Float64?
    getter folds : Int32?

    delegate alphabet, unigram, display, window, to: @search

    @prior_log_gamma : Slice(Float64)
    @empty_continuations : Array(Slice(Int32))
    @empty_folds : Array(Slice(Int32))
    @log_gamma_concentration : Float64

    def initialize(index : Index, window : Int32, @min_support : Int32, @concentration : Float64, @stop : Float64 = 0.5,
                   @suffixes_only : Bool = false, @hierarchical : Bool = false, @discount : Float64? = nil,
                   @chain_strength : Float64? = nil, @nearest_prior : Float64? = nil, @folds : Int32? = nil)
      raise ArgumentError.new("minimum support must be at least 1") if @min_support < 1
      if folds = @folds
        raise ArgumentError.new("cross-validation needs at least 2 folds") if folds < 2
        raise ArgumentError.new("cross-validation is defined for Dirichlet estimates") if @discount
      end
      if nearest = @nearest_prior
        raise ArgumentError.new("nearest-offset prior must be in (0, 1]") unless 0 < nearest <= 1
      end
      if chain = @chain_strength
        raise ArgumentError.new("continuation counts need hierarchical priors") unless @hierarchical
        raise ArgumentError.new("chain strength must be positive") unless chain > 0
      end
      if discount = @discount
        raise ArgumentError.new("discount must be between 0 and 1") unless 0 < discount < 1
        raise ArgumentError.new("strength must not be negative") if @concentration < 0
      else
        raise ArgumentError.new("concentration must be positive") unless @concentration > 0
      end
      raise ArgumentError.new("stop probability must be between 0 and 1") unless 0 < @stop < 1
      @search = LatticeSearch.new(index, window)
      @empty_continuations = Array(Slice(Int32)).new(window + 1) do |offset|
        @chain_strength && offset > 0 ? @search.empty_continuation_counts(offset) : Slice(Int32).new(0)
      end
      @empty_folds = (folds = @folds) ? @search.empty_fold_counts(folds) : [] of Slice(Int32)
      @prior_log_gamma = Slice(Float64).new(alphabet.size) { |slot| Math.lgamma(@concentration * unigram[slot]) }
      @log_gamma_concentration = Math.lgamma(@concentration)
    end

    # Natural-log probability of next-byte counts under the Dirichlet prior
    # centered on P_0, in any order.
    def log_evidence(counts : Slice(Int32), support : Int32) : Float64
      return 0.0 if support == 0
      total = @log_gamma_concentration - Math.lgamma(support + @concentration)
      counts.each_with_index do |count, slot|
        next if count == 0
        total += Math.lgamma(count + @concentration * unigram[slot]) - @prior_log_gamma[slot]
      end
      total
    end

    # Cross-validated log-probability of matches split into folds: each fold
    # predicted from the others' counts with a Dirichlet prior centered on `mean`.
    def cross_validated_evidence(by_fold : Array(Slice(Int32)), mean : Slice(Float64)) : Float64
      totals = Slice(Int32).new(alphabet.size) { |slot| by_fold.sum { |fold| fold[slot] } }
      size = totals.sum
      result = 0.0
      by_fold.each do |fold|
        held = fold.sum
        next if held == 0
        denominator = size - held + @concentration
        fold.each_with_index do |count, slot|
          next if count == 0
          result += count * Math.log((totals[slot] - count + @concentration * mean[slot]) / denominator)
        end
      end
      result
    end

    # The same, for a prior centered on `mean`: Dirichlet, or Pitman–Yor when
    # a discount is set.
    def log_evidence(counts : Slice(Int32), support : Int32, mean : Slice(Float64)) : Float64
      return 0.0 if support == 0
      if discount = @discount
        distinct = 0
        total = Math.lgamma(@concentration + 1) - Math.lgamma(@concentration + support)
        counts.each_with_index do |count, slot|
          next if count == 0
          distinct += 1
          total += Math.log(mean[slot]) + Math.lgamma(count - discount) - Math.lgamma(1 - discount)
        end
        1.upto(distinct - 1) { |j| total += Math.log(@concentration + j * discount) }
        return total
      end
      total = @log_gamma_concentration - Math.lgamma(support + @concentration)
      counts.each_with_index do |count, slot|
        next if count == 0
        prior = @concentration * mean[slot]
        total += Math.lgamma(count + prior) - Math.lgamma(prior)
      end
      total
    end

    # Posterior mean next-byte estimate by slot, for counts and a prior mean.
    def estimate(counts : Slice(Int32), support : Int32, mean : Slice(Float64)) : Slice(Float64)
      if discount = @discount
        distinct = counts.count(&.> 0)
        escape = (@concentration + discount * distinct) / (@concentration + support)
        Slice(Float64).new(alphabet.size) do |slot|
          Math.max(counts[slot] - discount, 0.0) / (@concentration + support) + escape * mean[slot]
        end
      else
        Slice(Float64).new(alphabet.size) do |slot|
          (counts[slot] + @concentration * mean[slot]) / (support + @concentration)
        end
      end
    end

    # Prior probability of each supported refinement of `shape`, given that it
    # refines, and the share of refining that has no supported target (it goes
    # to stopping): uniform over the supported refinements, or p for the
    # nearest unfixed offset and 1 − p shared by the others.
    def refinement_shares(shape : UInt32, refined : Array(UInt32), limit : Int32) : Tuple(Array(Float64), Float64)
      nearest = @nearest_prior
      return {refined.map { 1.0 / refined.size }, 0.0} unless nearest
      missing = (1..limit).find { |offset| shape.bit(offset - 1) == 0 }
      closest = missing ? shape | (1_u32 << (missing - 1)) : nil
      has_closest = refined.includes?(closest)
      others = refined.size - (has_closest ? 1 : 0)
      shares = refined.map { |child| child == closest ? nearest : (1 - nearest) / others }
      {shares, (has_closest ? 0.0 : nearest) + (others > 0 ? 0.0 : 1 - nearest)}
    end

    # Offsets whose addition makes `shape` the parent: farther than its
    # farthest offset (only the next one for suffixes), within `limit`.
    def child_offsets(shape : UInt32, limit : Int32) : Array(Int32)
      farthest = 32 - shape.leading_zeros_count
      return farthest < limit ? [farthest + 1] : [] of Int32 if @suffixes_only
      ((farthest + 1)..limit).to_a
    end

    # A continuation estimate: counts N interpolated with `mean` at strength `chain`.
    def chained(continuation : Slice(Int32), mean : Slice(Float64), chain : Float64) : Slice(Float64)
      total = continuation.sum
      Slice(Float64).new(alphabet.size) { |slot| (continuation[slot] + chain * mean[slot]) / (total + chain) }
    end

    # The pattern without its farthest offset.
    def parent(shape : UInt32) : UInt32
      shape & ~(1_u32 << (31 - shape.leading_zeros_count))
    end

    # Patterns with positive weight, heaviest first; the weights sum to 1.
    def patterns(history : Bytes) : Array(SufficientPattern)
      shapes = [] of UInt32
      supports = [] of Int32
      counts = [] of Slice(Int32)
      found = {} of UInt32 => Int32
      limit = Math.min(window, history.size)
      # Continuation counts of each pattern for the offsets its children add,
      # and its counts by fold.
      continuations = [] of Hash(Int32, Slice(Int32))
      by_fold = [] of Array(Slice(Int32))
      @search.each(history, @min_support) do |shape, support, next_counts, depth|
        next false if @suffixes_only && !suffix?(shape)
        found[shape] = shapes.size
        shapes << shape
        supports << support
        counts << next_counts
        by_offset = {} of Int32 => Slice(Int32)
        if @chain_strength
          child_offsets(shape, limit).each do |offset|
            by_offset[offset] = shape == 0 ? @empty_continuations[offset] : @search.continuation_counts(depth, offset)
          end
        end
        continuations << by_offset
        if folds = @folds
          by_fold << (shape == 0 ? @empty_folds : @search.fold_counts(depth, folds))
        end
        true
      end
      size = shapes.size
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

      # Each pattern's estimate, and the prior mean its own matches and its
      # disagreeing matches are judged against.
      order = (0...size).to_a.sort_by { |i| -shapes[i].popcount }
      estimates = Array(Slice(Float64)).new(size) { Slice(Float64).new(0) }
      means = Array(Slice(Float64)).new(size) { unigram }
      order.reverse_each do |i|
        if @hierarchical && shapes[i] != 0
          up = found[parent(shapes[i])]
          means[i] = if chain = @chain_strength
                       added = 32 - shapes[i].leading_zeros_count
                       chained(continuations[up][added], means[up], chain)
                     else
                       estimates[up]
                     end
        end
        estimates[i] = estimate(counts[i], supports[i], means[i])
      end
      evidence_of = ->(next_counts : Slice(Int32), support : Int32, i : Int32) do
        @hierarchical || @discount ? log_evidence(next_counts, support, means[i]) : log_evidence(next_counts, support)
      end

      # From the most specific patterns up: log weighted probability of each
      # pattern's matches, and the posterior shares of stopping or refining.
      weighted = Array(Float64).new(size, 0.0)
      stop_share = Array(Float64).new(size, 1.0)
      refine_shares = Array(Array(Float64)).new(size) { [] of Float64 }
      order.each do |i|
        evidence = @folds ? cross_validated_evidence(by_fold[i], means[i]) : evidence_of.call(counts[i], supports[i], i)
        if children[i].empty?
          weighted[i] = evidence
          next
        end
        shares, unused = refinement_shares(shapes[i], children[i].map { |child| shapes[child] }, limit)
        stop_term = Math.log(@stop + (1 - @stop) * unused) + evidence
        terms = children[i].map_with_index do |child, j|
          disagreeing = if @folds
                          rest_by_fold = by_fold[i].map_with_index do |fold, f|
                            Slice(Int32).new(alphabet.size) { |slot| fold[slot] - by_fold[child][f][slot] }
                          end
                          cross_validated_evidence(rest_by_fold, means[i])
                        else
                          rest = Slice(Int32).new(alphabet.size) { |slot| counts[i][slot] - counts[child][slot] }
                          evidence_of.call(rest, supports[i] - supports[child], i)
                        end
          Math.log(1 - @stop) + Math.log(shares[j]) + disagreeing + weighted[child]
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
        SufficientPattern.new(shapes[i], supports[i], counts[i], weight, estimates[i]) if weight > 0
      end.sort_by { |pattern| {-pattern.weight, pattern.shape} }
    end

    # Whether the shape is the offsets 1..k for some k.
    def suffix?(shape : UInt32) : Bool
      shape & (shape &+ 1) == 0
    end

    def distribution(patterns : Array(SufficientPattern)) : Slice(Float64)
      total = patterns.sum(&.weight)
      result = Slice(Float64).new(256, FLOOR / 256)
      patterns.each do |pattern|
        share = (1 - FLOOR) * pattern.weight / total
        alphabet.each_with_index { |byte, slot| result[byte] += share * pattern.estimate[slot] }
      end
      result
    end

    def probability(patterns : Array(SufficientPattern), byte : UInt8) : Float64
      slot = @search.slot(byte)
      return FLOOR / 256 if slot < 0
      total = patterns.sum(&.weight)
      (1 - FLOOR) * patterns.sum { |pattern| pattern.weight * pattern.estimate[slot] } / total + FLOOR / 256
    end
  end
end
