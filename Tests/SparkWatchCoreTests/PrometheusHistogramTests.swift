import Foundation
import Testing

@testable import SparkWatchCore

/// Latency percentiles from the engine's own histograms.
///
/// The fixture is **verbatim output from spark-a:18000** (TensorFold,
/// 2026-10-10), not a hand-made example — the point of these tests is that the
/// arithmetic holds on the numbers the box actually produces, including the two
/// cases where the honest answer is "not in the data".
@Suite("延迟直方图分位")
struct PrometheusHistogramTests {
    static let live = """
    # HELP tensorfold:request_latency_seconds Completed request latency.
    # TYPE tensorfold:request_latency_seconds histogram
    tensorfold:request_latency_seconds_bucket{le="0.01"} 0
    tensorfold:request_latency_seconds_bucket{le="0.05"} 0
    tensorfold:request_latency_seconds_bucket{le="0.1"} 0
    tensorfold:request_latency_seconds_bucket{le="0.25"} 1
    tensorfold:request_latency_seconds_bucket{le="0.5"} 8
    tensorfold:request_latency_seconds_bucket{le="1"} 31
    tensorfold:request_latency_seconds_bucket{le="2.5"} 246
    tensorfold:request_latency_seconds_bucket{le="5"} 549
    tensorfold:request_latency_seconds_bucket{le="10"} 857
    tensorfold:request_latency_seconds_bucket{le="30"} 1168
    tensorfold:request_latency_seconds_bucket{le="60"} 1270
    tensorfold:request_latency_seconds_bucket{le="120"} 1314
    tensorfold:request_latency_seconds_bucket{le="300"} 1335
    tensorfold:request_latency_seconds_bucket{le="+Inf"} 1396
    tensorfold:request_latency_seconds_sum 100977.573381
    tensorfold:request_latency_seconds_count 1396
    tensorfold:time_to_first_token_seconds_bucket{le="0.01"} 0
    tensorfold:time_to_first_token_seconds_bucket{le="0.05"} 0
    tensorfold:time_to_first_token_seconds_bucket{le="0.1"} 0
    tensorfold:time_to_first_token_seconds_bucket{le="0.25"} 9
    tensorfold:time_to_first_token_seconds_bucket{le="0.5"} 36
    tensorfold:time_to_first_token_seconds_bucket{le="1"} 646
    tensorfold:time_to_first_token_seconds_bucket{le="2.5"} 1159
    tensorfold:time_to_first_token_seconds_bucket{le="5"} 1274
    tensorfold:time_to_first_token_seconds_bucket{le="10"} 1302
    tensorfold:time_to_first_token_seconds_bucket{le="30"} 1322
    tensorfold:time_to_first_token_seconds_bucket{le="60"} 1337
    tensorfold:time_to_first_token_seconds_bucket{le="120"} 1344
    tensorfold:time_to_first_token_seconds_bucket{le="300"} 1353
    tensorfold:time_to_first_token_seconds_bucket{le="+Inf"} 1392
    tensorfold:time_to_first_token_seconds_sum 50886.79595
    tensorfold:time_to_first_token_seconds_count 1392
    tensorfold:generation_tokens_total 898702
    tensorfold:prompt_tokens_total 141006155
    tensorfold:requests_running 1
    tensorfold:kv_cache_usage_ratio{pool="0"} 0.346
    """

    @Test func liveFixtureYieldsTTFTPercentileAndMean() {
        let snapshot = try? #require(PrometheusParser.parse(Self.live))
        #expect(snapshot?.engine == "TensorFold")
        // 0.95 × 1392 = 1322.4 → between the 30 s bucket (1322) and the 60 s one
        // (1337): 30 + (0.4/15)×30 ≈ 30.8 s.
        let p95 = try? #require(snapshot?.ttftP95Seconds)
        #expect(abs((p95 ?? 0) - 30.8) < 0.2)
        // Mean = sum ÷ count = 50886.79595 / 1392 ≈ 36.6 s. Note it is *above* the
        // p95: a minority of very long prefills pull it up — which is exactly why a
        // mean alone is not enough.
        let mean = try? #require(snapshot?.ttftMeanSeconds)
        #expect(abs((mean ?? 0) - 36.56) < 0.1)
        #expect((mean ?? 0) > (p95 ?? 0))
    }

    @Test func liveFixtureYieldsEndToEndPercentile() {
        let snapshot = PrometheusParser.parse(Self.live)
        // 0.95 × 1396 = 1326.2 → between 120 s (1314) and 300 s (1335):
        // 120 + (12.2/21)×180 ≈ 224.6 s.
        let p95 = try? #require(snapshot?.e2eP95Seconds)
        #expect(abs((p95 ?? 0) - 224.6) < 1.0)
    }

    /// An engine that exports no inter-token histogram must produce nothing, not a
    /// zero — a zero would read as "instant" in the panel.
    @Test func absentHistogramStaysAbsent() {
        let snapshot = PrometheusParser.parse(Self.live)
        #expect(snapshot?.itlP95Seconds == nil)
    }

    @Test func quantileIsRefusedWhenTheTargetIsInTheInfiniteTail() {
        // Finite buckets cover only 10 of 100 samples: the 95th percentile is not
        // bounded by any exported boundary, so there is no honest number to give.
        let buckets: [Double: Double] = [1: 5, 2: 10, .infinity: 100]
        #expect(PrometheusParser.quantile(0.95, buckets: buckets, count: 100) == nil)
        // The 10th percentile *is* bounded, and interpolates inside the first bucket.
        let p10 = PrometheusParser.quantile(0.10, buckets: buckets, count: 100)
        #expect(p10 == 2)   // 10 samples sit at ≤2 s; target 10 lands exactly on it
    }

    @Test func aPartiallyScrapedHistogramIsRefused() {
        // `+Inf` disagrees with `_count` — one of the two series was missing from the
        // scrape. A quantile computed over half a histogram is worse than none.
        let buckets: [Double: Double] = [1: 50, 2: 100, .infinity: 100]
        #expect(PrometheusParser.quantile(0.95, buckets: buckets, count: 1396) == nil)
        // …but the same buckets are fine when the count agrees.
        #expect(PrometheusParser.quantile(0.95, buckets: buckets, count: 100) != nil)
    }

    @Test func noBucketsMeansNoAnswer() {
        #expect(PrometheusParser.quantile(0.95, buckets: nil, count: nil) == nil)
        #expect(PrometheusParser.quantile(0.95, buckets: [:], count: 0) == nil)
        #expect(PrometheusParser.quantile(0.95, buckets: [.infinity: 0], count: 0) == nil)
    }

    /// A metric split across label sets (engines, tensor-parallel ranks) has several
    /// bucket series per boundary. Taking only the first would compute the percentile
    /// over a fraction of the requests — the same class of bug as summing only the
    /// first `is_streaming` series.
    @Test func bucketSeriesAcrossLabelsAreSummedPerBoundary() {
        let text = """
        tensorfold:time_to_first_token_seconds_bucket{engine="a",le="1"} 10
        tensorfold:time_to_first_token_seconds_bucket{engine="b",le="1"} 20
        tensorfold:time_to_first_token_seconds_bucket{engine="a",le="+Inf"} 50
        tensorfold:time_to_first_token_seconds_bucket{engine="b",le="+Inf"} 50
        tensorfold:time_to_first_token_seconds_count{engine="a"} 50
        tensorfold:time_to_first_token_seconds_count{engine="b"} 50
        tensorfold:time_to_first_token_seconds_sum{engine="a"} 25
        tensorfold:time_to_first_token_seconds_sum{engine="b"} 25
        tensorfold:generation_tokens_total 1
        """
        let snapshot = try? #require(PrometheusParser.parse(text))
        // 100 samples, 30 of them ≤1 s → p95 needs the interpolated range [1, +Inf),
        // which is unbounded → nil rather than "1 s".
        #expect(snapshot?.ttftP95Seconds == nil)
        // The mean is well defined from the summed sum/count: 50/100 = 0.5 s.
        #expect(snapshot?.ttftMeanSeconds == 0.5)
    }
}
