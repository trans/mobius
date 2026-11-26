require "spec"
require "../src/mobius/interactions"

# Next-byte counts (by byte) of training positions whose bytes at `offsets`
# equal the corpus bytes at the same offsets before `position`.
def naive_counts(text : Bytes, offsets : Array(Int32), corpus : Bytes, position : Int32) : Array(Int32)
  counts = Array(Int32).new(256, 0)
  text.size.times do |t|
    next unless offsets.all? { |o| t - o >= 0 && text[t - o] == corpus[position - o] }
    counts[text[t]] += 1
  end
  counts
end

# Witten–Bell toward the shape without its farthest offset, ending uniform.
def naive_witten_bell(text : Bytes, offsets : Array(Int32), corpus : Bytes, position : Int32) : Array(Float64)
  lower = offsets.empty? ? Array(Float64).new(256, 1.0 / 256) : naive_witten_bell(text, offsets.sort[0...-1], corpus, position)
  counts = naive_counts(text, offsets, corpus, position)
  total = counts.sum
  distinct = counts.count(&.> 0)
  (0...256).map { |byte| (counts[byte] + distinct * lower[byte]) / (total + distinct) }
end

def offsets_of(mask : UInt32) : Array(Int32)
  (1..32).select { |o| mask.bit(o - 1) == 1 }
end

def subsets_of(mask : UInt32) : Array(UInt32)
  result = [] of UInt32
  subset = mask
  loop do
    result << subset
    break if subset == 0
    subset = (subset &- 1) & mask
  end
  result
end

describe Mobius::InteractionModel do
  corpus = begin
    random = Random.new(5)
    String.build { |io| 400.times { io << "abc d."[random.rand(6)] } }.to_slice
  end
  training = corpus[0, 300]
  model = Mobius::InteractionModel.new(training, 5, 3, 2, 2, 1_000_000)

  it "counts every kept pattern exactly" do
    model.ranked.should_not be_empty
    model.ranked.each do |pattern|
      offsets = offsets_of(pattern.shape)
      position = (offsets.max...training.size).find { |t| model.key_at(training, pattern.shape, t) == pattern.key }.not_nil!
      expected = naive_counts(training, offsets, training, position)
      model.alphabet.each_with_index { |byte, slot| pattern.counts[slot].should eq(expected[byte]) }
      pattern.support.should eq(expected.sum)
      pattern.support.should be >= 2
      (pattern.shape & ~0b11_u32).should_not eq(0)
    end
  end

  it "scores each pattern by its smallest gain over a parent, less the chance allowance" do
    model.ranked.first(40).each do |pattern|
      offsets = offsets_of(pattern.shape)
      position = (offsets.max...training.size).find { |t| model.key_at(training, pattern.shape, t) == pattern.key }.not_nil!
      counts = naive_counts(training, offsets, training, position)
      gains = offsets.map do |removed|
        parent = naive_counts(training, offsets - [removed], training, position)
        (0...256).sum(0.0) do |byte|
          next 0.0 if counts[byte] == 0
          counts[byte] * Math.log2((counts[byte] / counts.sum) / (parent[byte] / parent.sum))
        end
      end
      expected = gains.min - (counts.count(&.> 0) - 1) / (2 * Math.log(2.0))
      pattern.score.should be_close(expected, 1e-9)
    end
    model.ranked.each_cons_pair { |a, b| (a.score >= b.score).should be_true }
  end

  it "keeps the same top patterns under a smaller capacity" do
    small = Mobius::InteractionModel.new(training, 5, 3, 2, 2, 25)
    small.ranked.map { |p| {p.shape, p.key} }.should eq(model.ranked.first(25).map { |p| {p.shape, p.key} })
  end

  it "equals the definition: Kneser–Ney plus Möbius terms beyond its context" do
    inside = 0b11_u32
    300.upto(329) do |position|
      base = model.base_scores(corpus, position)
      {0, 10, 200, model.ranked.size}.each do |active|
        matched = model.ranked.first(active).select do |pattern|
          model.key_at(corpus, pattern.shape, position) == pattern.key
        end.map(&.shape)
        terms = matched.flat_map { |shape| subsets_of(shape) }.uniq.select { |t| t & ~inside != 0 }
        expected = model.alphabet.map { |byte| base[model.alphabet.index(byte).not_nil!] }
        terms.each do |term|
          subsets_of(term).each do |subset|
            sign = (term.popcount - subset.popcount).even? ? 1 : -1
            values = naive_witten_bell(training, offsets_of(subset), corpus, position)
            model.alphabet.each_with_index { |byte, slot| expected[slot] += sign * Math.log(values[byte]) }
          end
        end
        actual = model.log_scores(corpus, position, active, base)
        model.alphabet.size.times { |slot| actual[slot].should be_close(expected[slot], 1e-9) }
      end
    end
  end

  it "normalizes over all 256 bytes and reduces to Kneser–Ney with no patterns" do
    310.upto(319) do |position|
      base = model.base_scores(corpus, position)
      {0, 50, model.ranked.size}.each do |active|
        scores = model.log_scores(corpus, position, active, base)
        (0..255).sum { |byte| model.probability(scores, byte.to_u8) }.should be_close(1.0, 1e-12)
      end
      kneser_ney = model.kneser_ney.probability(corpus[0, position], corpus[position], 2)
      model.probability(corpus, position, 0).should be_close(kneser_ney, 1e-12)
    end
  end
end
