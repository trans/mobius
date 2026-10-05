require "spec"
require "../src/mobius/lattice"

# All patterns consistent with the history (subsets of offsets 1..window),
# with support at least `min_support`, identical counts kept once, highest
# weight first. Counts come from scanning; leave-one-out bits from literally
# removing each match and re-estimating from the rest.
def lattice_brute_force(training : Bytes, alphabet : Bytes, history : Bytes, window : Int32, min_support : Int32) : Array(Tuple(Float64, Int32, Array(Int32)))
  unigram = alphabet.to_a.map { |byte| training.count(byte) / training.size }
  results = [] of Tuple(Float64, Int32, Array(Int32))
  limit = Math.min(window, history.size)
  (0...(1 << limit)).each do |mask|
    offsets = (1..limit).select { |o| mask.bit(o - 1) == 1 }
    matches = (0...training.size).select do |t|
      offsets.all? { |o| t - o >= 0 && training[t - o] == history[history.size - o] }
    end
    next if matches.size < min_support && mask != 0
    counts = alphabet.to_a.map { |byte| matches.count { |t| training[t] == byte } }
    bits = matches.sum do |t|
      slot = alphabet.index(training[t]).not_nil!
      rest = counts.dup
      rest[slot] -= 1
      if matches.size == 1
        -Math.log2(unigram[slot])
      else
        distinct = rest.count(&.> 0)
        -Math.log2((rest[slot] + distinct * unigram[slot]) / (matches.size - 1 + distinct))
      end
    end / matches.size
    results << {2.0 ** -bits, matches.size, counts}
  end
  results.uniq { |_, support, counts| {support, counts} }.sort_by { |weight, _, _| -weight }
end

describe Mobius::Index do
  it "restricts a match set by a byte at any offset" do
    random = Random.new(2)
    corpus = String.build { |io| 300.times { io << "abcd"[random.rand(4)] } }.to_slice
    index = Mobius::Index.from_bytes(corpus.dup)
    set = index.full_set
    target = Slice(UInt64).new(index.word_count, 0_u64)
    [{1, 'a'}, {5, 'b'}, {63, 'c'}, {64, 'd'}, {65, 'a'}, {130, 'b'}].each do |offset, char|
      count = index.restrict(set, target, char.ord.to_u8, offset)
      expected = (0...300).select { |p| p >= offset && corpus[p - offset] == char.ord }
      actual = (0...300).select { |p| target[p // 64].bit(p % 64) == 1 }
      actual.should eq(expected)
      count.should eq(expected.size)
    end
  end
end

describe Mobius::Index do
  it "chains restrictions, each narrowing the previous match set" do
    random = Random.new(12)
    corpus = String.build { |io| 400.times { io << "abc"[random.rand(3)] } }.to_slice
    index = Mobius::Index.from_bytes(corpus.dup)
    first = Slice(UInt64).new(index.word_count, 0_u64)
    second = Slice(UInt64).new(index.word_count, 0_u64)
    third = Slice(UInt64).new(index.word_count, 0_u64)
    index.restrict(index.full_set, first, 'a'.ord.to_u8, 2)
    index.restrict(first, second, 'b'.ord.to_u8, 70)
    count = index.restrict(second, third, 'c'.ord.to_u8, 129)
    expected = (0...400).select { |p| p >= 129 && corpus[p - 2] == 'a'.ord && corpus[p - 70] == 'b'.ord && corpus[p - 129] == 'c'.ord }
    (0...400).select { |p| third[p // 64].bit(p % 64) == 1 }.should eq(expected)
    count.should eq(expected.size)
    expected.should_not be_empty
  end
end

describe Mobius::LatticePredictor do
  corpus = begin
    random = Random.new(17)
    String.build { |io| 600.times { io << "abc d.\n"[random.rand(7)] } }.to_slice
  end
  training = corpus[0, 500].dup
  index = Mobius::Index.from_bytes(training)

  it "keeps exactly the top patterns a brute-force search finds, despite pruning" do
    {
      {2, 5}, {2, 1_000}, {4, 3}, {1, 10},
    }.each do |min_support, capacity|
      predictor = Mobius::LatticePredictor.new(index, 6, min_support, capacity)
      500.step(to: 560, by: 4).each do |position|
        history = corpus[0, position]
        expected = lattice_brute_force(training, predictor.alphabet, history, 6, min_support).first(capacity)
        actual = predictor.patterns(history)
        actual.map(&.weight).zip(expected.map(&.[0])).each { |a, e| a.should be_close(e, 1e-12) }
        actual.size.should eq(expected.size)
        actual.map { |p| {p.support, p.counts.to_a} }.sort.should eq(expected.map { |_, s, c| {s, c} }.sort) if capacity == 1_000
      end
    end
  end

  it "prunes only branches that cannot reach the top on predictable text" do
    random = Random.new(8)
    text = String.build do |io|
      700.times { |i| io << (random.rand < 0.04 ? "xyz"[random.rand(3)] : "the cat sat. "[i % 13]) }
    end.to_slice
    repetitive = text[0, 600].dup
    predictable = Mobius::Index.from_bytes(repetitive)
    {
      {1, 1}, {1, 3}, {2, 2}, {3, 6},
    }.each do |min_support, capacity|
      predictor = Mobius::LatticePredictor.new(predictable, 6, min_support, capacity)
      600.step(to: 690, by: 3).each do |position|
        history = text[0, position]
        expected = lattice_brute_force(repetitive, predictor.alphabet, history, 6, min_support).first(capacity)
        actual = predictor.patterns(history)
        actual.size.should eq(expected.size)
        actual.map(&.weight).zip(expected.map(&.[0])).each { |a, e| a.should be_close(e, 1e-12) }
      end
    end
  end

  it "bounds pruning by the best weight a pattern with that support can reach" do
    predictor = Mobius::LatticePredictor.new(index, 6, 1, 4)
    size = predictor.alphabet.size
    random = Random.new(6)
    1.upto(40) do |support|
      same = (0...size).map do |slot|
        counts = Slice(Int32).new(size, 0)
        counts[slot] = support
        2.0 ** -predictor.leave_one_out_bits(counts, support)
      end
      predictor.attainable(support).should be_close(same.max, 1e-12)
      20.times do
        counts = Slice(Int32).new(size, 0)
        support.times { counts[random.rand(size)] += 1 }
        (2.0 ** -predictor.leave_one_out_bits(counts, support)).should be <= predictor.attainable(support) + 1e-12
      end
    end
  end

  it "averages pattern estimates by weight into a normalized distribution" do
    predictor = Mobius::LatticePredictor.new(index, 6, 2, 8)
    alphabet = predictor.alphabet
    {505, 533, 571}.each do |position|
      patterns = predictor.patterns(corpus[0, position])
      {1, 3, patterns.size}.each do |limit|
        distribution = predictor.distribution(patterns, limit)
        distribution.sum.should be_close(1.0, 1e-12)
        used = patterns.first(limit)
        total = used.sum(&.weight)
        alphabet.each_with_index do |byte, slot|
          mixed = used.sum do |p|
            distinct = p.counts.count(&.> 0)
            p.weight * (p.counts[slot] + distinct * predictor.unigram[slot]) / (p.support + distinct)
          end / total
          distribution[byte].should be_close((1 - 1e-6) * mixed + 1e-6 / 256, 1e-12)
          predictor.probability(patterns, byte, limit).should be_close(distribution[byte], 1e-12)
        end
        distribution['z'.ord].should be_close(1e-6 / 256, 1e-18)
      end
    end
  end

  it "renders patterns in query syntax" do
    predictor = Mobius::LatticePredictor.new(index, 6, 1, 4)
    history = "xa\nb*d".to_slice
    predictor.display(0b101001_u32, history).should eq("x*\\n**d")
    predictor.display(0b000011_u32, history).should eq("\\*d")
    predictor.display(0_u32, history).should eq("(none)")
  end
end
