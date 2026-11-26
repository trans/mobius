require "spec"
require "../src/mobius/residual"

def residual_offsets(mask : UInt32) : Array(Int32)
  (1..32).select { |o| mask.bit(o - 1) == 1 }
end

# The pattern's bytes by offset, read from its first training match.
def residual_bytes(model : Mobius::ResidualModel, text : Bytes, pattern : Mobius::ResidualPattern) : Hash(Int32, UInt8)
  offsets = residual_offsets(pattern.shape)
  position = (offsets.max...text.size).find { |t| model.key_at(text, pattern.shape, t) == pattern.key }.not_nil!
  offsets.to_h { |o| {o, text[position - o]} }
end

def residual_matches?(bytes : Hash(Int32, UInt8), corpus : Bytes, position : Int32) : Bool
  bytes.all? { |o, byte| position - o >= 0 && corpus[position - o] == byte }
end

describe Mobius::KneserNey do
  it "gives the whole distribution consistently with per-byte probabilities" do
    random = Random.new(3)
    training = String.build { |io| 300.times { io << "abc d."[random.rand(6)] } }.to_slice
    model = Mobius::KneserNey.new(Mobius::SuffixArray.new(training), 4)
    {"", "a", "c d", "zzz", "ab.ab", "d.c"}.each do |text|
      levels = model.levels(text.to_slice)
      0.upto(4) do |limit|
        distribution = model.distribution(levels, limit)
        256.times { |byte| distribution[byte].should be_close(model.probabilities(levels, byte.to_u8)[limit], 1e-15) }
      end
    end
  end
end

describe Mobius::ResidualModel do
  corpus = begin
    random = Random.new(9)
    String.build { |io| 400.times { io << "abc d."[random.rand(6)] } }.to_slice
  end
  training = corpus[0, 300]
  model = Mobius::ResidualModel.new(training, 5, 3, 2, 2, 3, 0, 1_000_000)
  interleaved = Mobius::ResidualModel.new(training, 5, 3, 2, 2, 3, 7, 1_000_000)
  size = model.alphabet.size

  it "predicts each fold with Kneser–Ney trained on the other folds" do
    {
      {model, ->(position : Int32) { position * 3 // 300 }},
      {interleaved, ->(position : Int32) { (position // 7) % 3 }},
    }.each do |fitted, fold_of|
      3.times do |fold|
        members = (0...300).select { |position| fold_of.call(position) == fold }
        members.each { |position| fitted.fold_of(position).should eq(fold) }
        rest = Bytes.new(300 - members.size)
        (0...300).reject { |position| fold_of.call(position) == fold }.each_with_index { |position, i| rest[i] = training[position] }
        other = Mobius::KneserNey.new(Mobius::SuffixArray.new(rest), 2)
        members.each do |position|
          fitted.alphabet.each_with_index do |byte, slot|
            fitted.expected[position * size + slot].should be_close(other.probability(training[0, position], byte, 2), 1e-6)
          end
        end
      end
    end
  end

  it "scores each kept pattern from actual and expected counts at its matches" do
    model.ranked.should_not be_empty
    model.ranked.each do |pattern|
      bytes = residual_bytes(model, training, pattern)
      matches = (0...300).select { |t| residual_matches?(bytes, training, t) }
      pattern.support.should eq(matches.size)
      pattern.support.should be >= 2
      model.space.reaches_beyond?(pattern.shape).should be_true
      counts = Array(Int32).new(size, 0)
      expected = Array(Float64).new(size, 0.0)
      matches.each do |t|
        counts[model.alphabet.index(training[t]).not_nil!] += 1
        size.times { |slot| expected[slot] += model.expected[t * size + slot] }
      end
      score = -(counts.count(&.> 0) - 1) / (2 * Math.log(2.0))
      size.times do |slot|
        ratio = (counts[slot] + 1) / (expected[slot] + 1)
        score += counts[slot] * Math.log2(ratio) if counts[slot] > 0
        pattern.log_ratios[slot].should be_close(Math.log(ratio), 1e-9)
      end
      pattern.log_ratios[size].should eq(0.0)
      pattern.score.should be_close(score, 1e-9)
    end
    model.ranked.each_cons_pair { |a, b| (a.score >= b.score).should be_true }
  end

  it "keeps one pattern per distinct set of matching positions" do
    sets = model.ranked.map do |pattern|
      bytes = residual_bytes(model, training, pattern)
      (0...300).select { |t| residual_matches?(bytes, training, t) }
    end
    sets.uniq.size.should eq(sets.size)
    model.ranked.size.should be < model.candidates
  end

  it "keeps the same top patterns under a smaller capacity" do
    small = Mobius::ResidualModel.new(training, 5, 3, 2, 2, 3, 0, 20)
    small.ranked.map(&.score).should eq(model.ranked.first(small.ranked.size).map(&.score))
  end

  it "multiplies Kneser–Ney by the ratios of all matching patterns, or the best one" do
    patterns = model.ranked.map { |pattern| residual_bytes(model, training, pattern) }
    300.upto(339) do |position|
      base = model.base_scores(corpus, position)
      {0, 5, 50, model.ranked.size}.each do |active|
        matched = (0...active).select { |rank| residual_matches?(patterns[rank], corpus, position) }
        model.matching(corpus, position, active).should eq(matched)
        everything = model.log_scores(corpus, position, active, false, base)
        best_only = model.log_scores(corpus, position, active, true, base)
        (size + 1).times do |slot|
          everything[slot].should be_close(base[slot] + matched.sum(0.0) { |rank| model.ranked[rank].log_ratios[slot] }, 1e-9)
          best_only[slot].should be_close(base[slot] + (matched.first?.try { |rank| model.ranked[rank].log_ratios[slot] } || 0.0), 1e-9)
        end
        (0..255).sum { |byte| model.probability(everything, byte.to_u8) }.should be_close(1.0, 1e-12)
      end
      kneser_ney = model.kneser_ney.probability(corpus[0, position], corpus[position], 2)
      model.probability(model.log_scores(corpus, position, 0, false, base), corpus[position]).should be_close(kneser_ney, 1e-12)
    end
  end
end
