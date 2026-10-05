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
# Dirichlet predictive rule.
def sequential_evidence(counts : Array(Int32), unigram : Slice(Float64), concentration : Float64) : Float64
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
  evidence = sequential_evidence(counts, predictor.unigram, predictor.concentration)
  if refinements.empty?
    joint[offsets] += Math.exp(log_so_far + evidence)
  else
    joint[offsets] += Math.exp(log_so_far + Math.log(predictor.stop) + evidence)
    refinements.each do |o|
      child = (offsets + [o]).sort
      rest = counts.zip(sufficiency_counts(training, alphabet, child, history)).map { |a, b| a - b }
      step = Math.log(1 - predictor.stop) - Math.log(refinements.size) + sequential_evidence(rest, predictor.unigram, predictor.concentration)
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
