require "spec"
require "../src/mobius/recency"

# Counts over predicted bytes t in the last `span` positions before
# `position` whose k-byte context equals the one before `position`.
def recency_counts(corpus : Bytes, span : Int32, position : Int32, k : Int32, byte : UInt8) : Tuple(Int32, Int32, Int32)
  return {0, 0, 0} if k > position
  context = corpus[position - k, k]
  targets = (Math.max(0, position - span)...position).select { |t| t >= k && corpus[t - k, k] == context }
  nexts = targets.map { |t| corpus[t] }
  {nexts.count(byte), nexts.size, nexts.uniq.size}
end

describe Mobius::RecencyCache do
  corpus = begin
    random = Random.new(21)
    String.build { |io| 500.times { io << "abc d."[random.rand(6)] } }.to_slice
  end

  it "counts exactly what followed each recent context as the window slides" do
    cache = Mobius::RecencyCache.new(corpus, 37, 4, 3)
    [3, 4, 9, 40, 41, 77, 200, 201, 202, 350, 499].each do |position|
      cache.advance(position)
      0.upto(4) do |k|
        "abc d.z".each_byte do |byte|
          cache.counts(k, byte).should eq(recency_counts(corpus, 37, position, k, byte))
        end
      end
      longest = (0..4).to_a.reverse.find { |k| recency_counts(corpus, 37, position, k, 0_u8)[1] > 0 } || -1
      cache.longest.should eq(longest)
    end
  end

  it "interpolates contexts with Witten–Bell into a normalized distribution" do
    cache = Mobius::RecencyCache.new(corpus, 60, 5, 100)
    [100, 133, 260, 420].each do |position|
      cache.advance(position)
      (0..255).sum { |byte| cache.probability(byte.to_u8) }.should be_close(1.0, 1e-12)
      "abc".each_byte do |byte|
        expected = 1.0 / 256
        0.upto(cache.longest) do |k|
          count, total, distinct = recency_counts(corpus, 60, position, k, byte)
          expected = (count + distinct * expected) / (total + distinct)
        end
        cache.probability(byte).should be_close(expected, 1e-12)
      end
    end
  end

  it "starts empty at the beginning of the corpus" do
    cache = Mobius::RecencyCache.new(corpus, 10, 3, 0)
    cache.longest.should eq(-1)
    cache.probability('a'.ord.to_u8).should eq(1.0 / 256)
  end
end

describe Mobius::RecencyMixture do
  it "fits each bucket's weight to the likelihood maximum" do
    random = Random.new(4)
    kneser_ney = Array.new(2000) { random.rand(0.01..0.6) }
    cache = Array.new(2000) { |i| i.even? ? random.rand(0.2..0.9) : random.rand(0.001..0.05) }
    buckets = Array.new(2000) { |i| i % 3 }
    weights = Mobius::RecencyMixture.fit(kneser_ney, cache, buckets, 4, 500)
    weights[3].should eq(0.0)
    3.times do |bucket|
      members = (0...2000).select { |i| buckets[i] == bucket }
      likelihood = ->(w : Float64) { members.sum { |i| Math.log(Mobius::RecencyMixture.probability(kneser_ney[i], cache[i], w)) } }
      grid = (0..1000).map { |step| step / 1000.0 }.max_by { |w| likelihood.call(w) }
      weights[bucket].should be_close(grid, 0.002)
    end
  end
end
