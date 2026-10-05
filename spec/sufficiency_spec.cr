require "spec"
require "../src/mobius/sufficiency"

def sufficiency_counts(training : Bytes, alphabet : Bytes, offsets : Array(Int32), history : Bytes) : Array(Int32)
  counts = Array(Int32).new(alphabet.size, 0)
  training.size.times do |t|
    next unless offsets.all? { |o| t - o >= 0 && training[t - o] == history[history.size - o] }
    counts[alphabet.index(training[t]).not_nil!] += 1
  end
  counts
end

# Log probability of the counts as a sequence, one byte at a time, under the
# Dirichlet predictive rule with prior mean `unigram`.
def sequential_evidence(counts : Array(Int32), unigram : Indexable(Float64), concentration : Float64) : Float64
  total = 0.0
  seen = 0
  counts.each_with_index do |count, slot|
    count.times do |k|
      total += Math.log((k + concentration * unigram[slot]) / (seen + concentration))
      seen += 1
    end
  end
  total
end

# Log probability of the counts, drawn one at a time, under a Pitman–Yor
# prior with one table per distinct byte: a byte's first draw opens its table
# and is drawn from the mean; later draws join it.
def seating_evidence(counts : Array(Int32), mean : Indexable(Float64), strength : Float64, discount : Float64) : Float64
  total = 0.0
  seen = 0
  tables = 0
  counts.each_with_index.to_a.shuffle(Random.new(3)).each do |count, slot|
    count.times do |k|
      if k == 0
        total += Math.log((strength + discount * tables) / (strength + seen) * mean[slot]) unless seen == 0
        total += Math.log(mean[slot]) if seen == 0
        tables += 1
      else
        total += Math.log((k - discount) / (strength + seen))
      end
      seen += 1
    end
  end
  total
end

def pattern_evidence(counts : Array(Int32), mean : Indexable(Float64), predictor : Mobius::SufficiencyPredictor) : Float64
  if discount = predictor.discount
    seating_evidence(counts, mean, predictor.concentration, discount)
  else
    sequential_evidence(counts, mean, predictor.concentration)
  end
end

def sufficiency_fold_counts(training : Bytes, alphabet : Bytes, offsets : Array(Int32), history : Bytes, folds : Int32) : Array(Array(Int32))
  result = Array.new(folds) { Array(Int32).new(alphabet.size, 0) }
  training.size.times do |t|
    next unless offsets.all? { |o| t - o >= 0 && training[t - o] == history[history.size - o] }
    result[(t.to_i64 * folds // training.size).to_i][alphabet.index(training[t]).not_nil!] += 1
  end
  result
end

# Each fold's matches predicted from the sum of the other folds' counts.
def naive_cross_validated(by_fold : Array(Array(Int32)), mean : Array(Float64), beta : Float64) : Float64
  total = 0.0
  by_fold.each_with_index do |fold, f|
    others = Array(Int32).new(mean.size, 0)
    by_fold.each_with_index { |other, g| other.each_with_index { |c, slot| others[slot] += c } unless g == f }
    fold.each_with_index do |c, slot|
      total += c * Math.log((others[slot] + beta * mean[slot]) / (others.sum + beta)) if c > 0
    end
  end
  total
end

# The prior mean a pattern is judged against: plain frequency, or with
# hierarchical priors the estimate of the pattern without its farthest offset.
def sufficiency_mean(training : Bytes, predictor : Mobius::SufficiencyPredictor, history : Bytes, offsets : Array(Int32)) : Array(Float64)
  return predictor.unigram.to_a if offsets.empty? || !predictor.hierarchical?
  parent = offsets[0...-1]
  if chain = predictor.chain_strength
    # Continuation counts of the parent for the offset this pattern adds.
    added = offsets.last
    alphabet = predictor.alphabet
    distinct = Array.new(alphabet.size) { Set(Int32).new }
    training.size.times do |t|
      next unless parent.all? { |o| t - o >= 0 && training[t - o] == history[history.size - o] }
      distinct[alphabet.index(training[t]).not_nil!] << (t >= added ? training[t - added].to_i : 256)
    end
    counts = distinct.map(&.size)
    mean = sufficiency_mean(training, predictor, history, parent)
    counts.map_with_index { |count, slot| (count + chain * mean[slot]) / (counts.sum + chain) }
  else
    sufficiency_estimate(training, predictor, history, parent)
  end
end

def sufficiency_estimate(training : Bytes, predictor : Mobius::SufficiencyPredictor, history : Bytes, offsets : Array(Int32)) : Array(Float64)
  counts = sufficiency_counts(training, predictor.alphabet, offsets, history)
  mean = sufficiency_mean(training, predictor, history, offsets)
  beta = predictor.concentration
  if discount = predictor.discount
    escape = (beta + discount * counts.count(&.> 0)) / (beta + counts.sum)
    counts.map_with_index { |count, slot| Math.max(count - discount, 0.0) / (beta + counts.sum) + escape * mean[slot] }
  else
    counts.map_with_index { |count, slot| (count + beta * mean[slot]) / (counts.sum + beta) }
  end
end

# Adds to `joint` the probability of every refinement path from `offsets`,
# times the probability `log_so_far` of reaching it.
def sufficiency_paths(training : Bytes, predictor : Mobius::SufficiencyPredictor, history : Bytes,
                      offsets : Array(Int32), log_so_far : Float64, joint : Hash(Array(Int32), Float64)) : Nil
  alphabet = predictor.alphabet
  limit = Math.min(predictor.window, history.size)
  counts = sufficiency_counts(training, alphabet, offsets, history)
  candidates = if predictor.suffixes_only?
                 offsets == (1..offsets.size).to_a && offsets.size < limit ? [offsets.size + 1] : [] of Int32
               else
                 (1..limit).to_a - offsets
               end
  refinements = candidates.select do |o|
    sufficiency_counts(training, alphabet, (offsets + [o]).sort, history).sum >= predictor.min_support
  end
  mean = sufficiency_mean(training, predictor, history, offsets)
  folds = predictor.folds
  evidence = if folds
               naive_cross_validated(sufficiency_fold_counts(training, alphabet, offsets, history, folds), mean, predictor.concentration)
             else
               pattern_evidence(counts, mean, predictor)
             end
  if refinements.empty?
    joint[offsets] += Math.exp(log_so_far + evidence)
  else
    nearest = (1..limit).find { |o| !offsets.includes?(o) }
    stop = predictor.stop
    if p = predictor.nearest_prior
      others = refinements.count { |o| o != nearest }
      unused = (refinements.includes?(nearest) ? 0.0 : p) + (others > 0 ? 0.0 : 1 - p)
      stop += (1 - predictor.stop) * unused
    end
    joint[offsets] += Math.exp(log_so_far + Math.log(stop) + evidence)
    refinements.each do |o|
      child = (offsets + [o]).sort
      rest = counts.zip(sufficiency_counts(training, alphabet, child, history)).map { |a, b| a - b }
      share = if p = predictor.nearest_prior
                o == nearest ? p : (1 - p) / refinements.count { |r| r != nearest }
              else
                1.0 / refinements.size
              end
      next if share == 0
      disagreeing = if folds
                      whole = sufficiency_fold_counts(training, alphabet, offsets, history, folds)
                      refined = sufficiency_fold_counts(training, alphabet, child, history, folds)
                      split = whole.zip(refined).map { |w, r| w.zip(r).map { |a, b| a - b } }
                      naive_cross_validated(split, mean, predictor.concentration)
                    else
                      pattern_evidence(rest, mean, predictor)
                    end
      step = Math.log(1 - predictor.stop) + Math.log(share) + disagreeing
      sufficiency_paths(training, predictor, history, child, log_so_far + step, joint)
    end
  end
end

# Posterior probability that the refinement path ends at each pattern, by
# enumerating every path from the empty pattern.
def sufficiency_brute_force(training : Bytes, predictor : Mobius::SufficiencyPredictor, history : Bytes) : Hash(Array(Int32), Float64)
  joint = Hash(Array(Int32), Float64).new(0.0)
  sufficiency_paths(training, predictor, history, [] of Int32, 0.0, joint)
  total = joint.values.sum
  joint.transform_values { |value| value / total }
end

describe Mobius::SufficiencyPredictor do
  corpus = begin
    random = Random.new(31)
    String.build { |io| 360.times { |i| io << (random.rand < 0.3 ? "ab c."[random.rand(5)] : "abc ab. c"[i % 9]) } }.to_slice
  end
  training = corpus[0, 300].dup
  index = Mobius::Index.from_bytes(training)

  it "computes the Dirichlet evidence of counts in closed form" do
    predictor = Mobius::SufficiencyPredictor.new(index, 4, 1, 1.7)
    random = Random.new(1)
    10.times do
      counts = Array.new(predictor.alphabet.size) { random.rand(6) }
      predictor.log_evidence(Slice.new(counts.size) { |i| counts[i] }, counts.sum)
        .should be_close(sequential_evidence(counts, predictor.unigram, 1.7), 1e-9)
    end
  end

  it "weights each pattern by the posterior probability that refinement stops there" do
    { {1, 0.5, 0.5}, {2, 3.0, 0.5}, {3, 0.7, 0.3} }.each do |min_support, concentration, stop|
      predictor = Mobius::SufficiencyPredictor.new(index, 4, min_support, concentration, stop)
      300.step(to: 356, by: 7).each do |position|
        history = corpus[0, position]
        expected = sufficiency_brute_force(training, predictor, history)
        actual = predictor.patterns(history)
        actual.sum(&.weight).should be_close(1.0, 1e-9)
        actual.each do |pattern|
          offsets = (1..4).select { |o| pattern.shape.bit(o - 1) == 1 }
          pattern.weight.should be_close(expected[offsets], 1e-9)
          pattern.counts.to_a.should eq(sufficiency_counts(training, predictor.alphabet, offsets, history))
        end
        actual.size.should eq(expected.count { |_, weight| weight > 0 })
      end
    end
  end

  it "restricted to suffixes, refines only by the next older offset" do
    { {1, 0.5}, {2, 3.0} }.each do |min_support, concentration|
      predictor = Mobius::SufficiencyPredictor.new(index, 4, min_support, concentration, 0.5, suffixes_only: true)
      300.step(to: 356, by: 7).each do |position|
        history = corpus[0, position]
        expected = sufficiency_brute_force(training, predictor, history)
        actual = predictor.patterns(history)
        actual.sum(&.weight).should be_close(1.0, 1e-9)
        actual.each do |pattern|
          predictor.suffix?(pattern.shape).should be_true
          offsets = (1..4).select { |o| pattern.shape.bit(o - 1) == 1 }
          pattern.weight.should be_close(expected[offsets], 1e-9)
        end
        actual.size.should eq(expected.count { |_, weight| weight > 0 })
      end
    end
  end

  it "with parent-centered priors, matches every refinement path and its estimates" do
    { {1, 0.5, false}, {1, 4.0, false}, {2, 2.0, true} }.each do |min_support, concentration, suffixes_only|
      predictor = Mobius::SufficiencyPredictor.new(index, 4, min_support, concentration, 0.5,
        suffixes_only: suffixes_only, hierarchical: true)
      300.step(to: 356, by: 7).each do |position|
        history = corpus[0, position]
        expected = sufficiency_brute_force(training, predictor, history)
        actual = predictor.patterns(history)
        actual.sum(&.weight).should be_close(1.0, 1e-9)
        actual.each do |pattern|
          offsets = (1..4).select { |o| pattern.shape.bit(o - 1) == 1 }
          pattern.weight.should be_close(expected[offsets], 1e-9)
          sufficiency_estimate(training, predictor, history, offsets).each_with_index do |e, slot|
            pattern.estimate[slot].should be_close(e, 1e-12)
          end
        end
        actual.size.should eq(expected.count { |_, weight| weight > 0 })
      end
    end
  end

  it "computes Pitman–Yor evidence in closed form for the one-table-per-byte seating" do
    random = Random.new(9)
    {0.0, 1.5}.each do |strength|
      {0.3, 0.8}.each do |discount|
        predictor = Mobius::SufficiencyPredictor.new(index, 4, 1, strength, hierarchical: true, discount: discount)
        8.times do
          counts = Array.new(predictor.alphabet.size) { random.rand < 0.4 ? random.rand(1..7) : 0 }
          mean = Array.new(predictor.alphabet.size) { random.rand(0.01..1.0) }
          total = mean.sum
          mean = mean.map { |m| m / total }
          closed = predictor.log_evidence(Slice.new(counts.size) { |i| counts[i] }, counts.sum, Slice.new(mean.size) { |i| mean[i] })
          closed.should be_close(seating_evidence(counts, mean, strength, discount), 1e-9)
        end
      end
    end
  end

  it "with discounted estimates, matches every refinement path and its estimates" do
    { {1, 0.0, 0.75, false}, {1, 1.0, 0.5, false}, {2, 0.0, 0.9, true} }.each do |min_support, strength, discount, suffixes_only|
      predictor = Mobius::SufficiencyPredictor.new(index, 4, min_support, strength, 0.5,
        suffixes_only: suffixes_only, hierarchical: true, discount: discount)
      300.step(to: 356, by: 7).each do |position|
        history = corpus[0, position]
        expected = sufficiency_brute_force(training, predictor, history)
        actual = predictor.patterns(history)
        actual.sum(&.weight).should be_close(1.0, 1e-9)
        actual.each do |pattern|
          offsets = (1..4).select { |o| pattern.shape.bit(o - 1) == 1 }
          pattern.weight.should be_close(expected[offsets], 1e-9)
          estimate = sufficiency_estimate(training, predictor, history, offsets)
          estimate.sum.should be_close(1.0, 1e-12)
          estimate.each_with_index { |e, slot| pattern.estimate[slot].should be_close(e, 1e-12) }
        end
        actual.size.should eq(expected.count { |_, weight| weight > 0 })
      end
    end
  end

  it "with continuation-count parents, matches every refinement path and its estimates" do
    { {1, 4.0, 32.0, false}, {1, 2.0, 8.0, true}, {2, 1.0, 3.0, false} }.each do |min_support, strength, chain, suffixes_only|
      predictor = Mobius::SufficiencyPredictor.new(index, 4, min_support, strength, 0.5,
        suffixes_only: suffixes_only, hierarchical: true, chain_strength: chain)
      300.step(to: 356, by: 7).each do |position|
        history = corpus[0, position]
        expected = sufficiency_brute_force(training, predictor, history)
        actual = predictor.patterns(history)
        actual.sum(&.weight).should be_close(1.0, 1e-9)
        actual.each do |pattern|
          offsets = (1..4).select { |o| pattern.shape.bit(o - 1) == 1 }
          pattern.weight.should be_close(expected[offsets], 1e-9)
          sufficiency_estimate(training, predictor, history, offsets).each_with_index do |e, slot|
            pattern.estimate[slot].should be_close(e, 1e-12)
          end
        end
        actual.size.should eq(expected.count { |_, weight| weight > 0 })
      end
    end
  end

  it "with a nearest-offset prior, matches every refinement path" do
    { {1, 4.0, 32.0, 0.8}, {1, 2.0, nil, 0.5}, {2, 1.0, 8.0, 0.95} }.each do |min_support, strength, chain, nearest|
      predictor = Mobius::SufficiencyPredictor.new(index, 4, min_support, strength, 0.5,
        hierarchical: true, chain_strength: chain, nearest_prior: nearest)
      300.step(to: 356, by: 7).each do |position|
        history = corpus[0, position]
        expected = sufficiency_brute_force(training, predictor, history)
        actual = predictor.patterns(history)
        actual.sum(&.weight).should be_close(1.0, 1e-9)
        actual.each do |pattern|
          offsets = (1..4).select { |o| pattern.shape.bit(o - 1) == 1 }
          pattern.weight.should be_close(expected[offsets], 1e-9)
        end
        actual.size.should eq(expected.count { |_, weight| weight > 0 })
      end
    end
  end

  it "with the nearest offset certain, reduces to the suffix model" do
    masked = Mobius::SufficiencyPredictor.new(index, 4, 1, 4.0, 0.5, hierarchical: true, chain_strength: 32.0, nearest_prior: 1.0)
    suffixes = Mobius::SufficiencyPredictor.new(index, 4, 1, 4.0, 0.5, suffixes_only: true, hierarchical: true, chain_strength: 32.0)
    300.step(to: 356, by: 7).each do |position|
      history = corpus[0, position]
      expected = suffixes.patterns(history).to_h { |p| {p.shape, p.weight} }
      masked.patterns(history).each { |p| p.weight.should be_close(expected[p.shape]? || 0.0, 1e-12) }
      masked.probability(masked.patterns(history), corpus[position])
        .should be_close(suffixes.probability(suffixes.patterns(history), corpus[position]), 1e-12)
    end
  end

  it "with cross-validated evidence, matches every refinement path" do
    { {1, 4.0, 32.0, nil, 3, false}, {1, 2.0, nil, nil, 2, true}, {1, 4.0, 8.0, 0.9, 4, false} }.each do |min_support, strength, chain, nearest, folds, suffixes_only|
      predictor = Mobius::SufficiencyPredictor.new(index, 4, min_support, strength, 0.5,
        suffixes_only: suffixes_only, hierarchical: true, chain_strength: chain, nearest_prior: nearest, folds: folds)
      300.step(to: 356, by: 7).each do |position|
        history = corpus[0, position]
        expected = sufficiency_brute_force(training, predictor, history)
        actual = predictor.patterns(history)
        actual.sum(&.weight).should be_close(1.0, 1e-9)
        actual.each do |pattern|
          offsets = (1..4).select { |o| pattern.shape.bit(o - 1) == 1 }
          pattern.weight.should be_close(expected[offsets], 1e-9)
        end
        actual.size.should eq(expected.count { |_, weight| weight > 0 })
      end
    end
  end

  it "averages pattern estimates by weight into a normalized distribution" do
    predictor = Mobius::SufficiencyPredictor.new(index, 4, 2, 2.0)
    {301, 333}.each do |position|
      patterns = predictor.patterns(corpus[0, position])
      distribution = predictor.distribution(patterns)
      distribution.sum.should be_close(1.0, 1e-12)
      predictor.alphabet.each_with_index do |byte, slot|
        mixed = patterns.sum { |p| p.weight * (p.counts[slot] + 2.0 * predictor.unigram[slot]) / (p.support + 2.0) }
        distribution[byte].should be_close((1 - 1e-6) * mixed + 1e-6 / 256, 1e-12)
        predictor.probability(patterns, byte).should be_close(distribution[byte], 1e-12)
      end
    end
  end
end
