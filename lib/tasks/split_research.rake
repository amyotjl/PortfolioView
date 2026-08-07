# Reproducible evidence for PriceProvider::Yahoo's split classification (#66).
#
# WHY THIS IS A COMMITTED TASK AND NOT A THROWAWAY SCRIPT. The classification rule
# was rejected three times, and the third rejection was partly about EVIDENCE
# rather than behaviour: a claim in the source ("verified across all 15 genuine and
# 13 price-only factors observed on this feed") rested on a 28-factor sample chosen
# by the person proposing the rule, while an exhaustive sweep found 482 factors and
# at least 6 misclassifications. #71 had earned the same lesson: "a hand-picked
# ticker list always flatters whoever picked it."
#
# So the sweep that chose the current rule is checked in, and anyone — a tester
# especially — can re-run it and score the shipped code themselves rather than
# taking a comment's word for it.
#
#   bin/rails yahoo:collect_factors     # ~1,800 requests, several minutes
#   bin/rails yahoo:score_factors       # drives the SHIPPED method over the result
#
# NEVER RUN FROM CI OR A TEST. It calls the live, keyless, unofficial Yahoo chart
# endpoint (see the header of app/lib/price_provider/yahoo.rb) and paces itself so
# as not to hammer it. The hermetic unit tests in
# test/lib/price_provider/yahoo_test.rb encode the conclusions.
namespace :yahoo do
  CSV_PATH = "tmp/yahoo_factors.csv".freeze
  PACE = 0.25 # seconds between requests

  desc "Sweep the live Yahoo feed for split factors and record the evidence around each"
  task collect_factors: :environment do
    require "csv"

    adapter = PriceProvider::Yahoo.new

    # DETERMINISTIC, and stated so the sample can be criticised rather than
    # guessed at. No symbol is here because of what it would prove.
    held = Instrument.where(currency: "CAD").order(:symbol).pluck(:symbol)
    named = %w[
      HMMC.TO VTI.CN XCS.TO LCS.TO FTN.TO LUG.TO WCN.TO GURU.TO VDY.TO ZEQT.TO
      TRP.TO BN.TO HPS.A.TO FINN.NE META.TO GOOG.TO AAPL.TO QQC.TO XQQ.TO RAGE.V VVTM.V
    ]
    cad_ids = ListedInstrument.where(currency: "CAD").order(:id).pluck(:id)
    step = [ cad_ids.size / 1_600, 1 ].max
    spaced = ListedInstrument.where(id: cad_ids.each_slice(step).map(&:first)).pluck(:symbol)
    us = %w[AAPL GOOG GOOGL WKHS TSLA NVDA AMZN MSFT SHOP CGC PLUG F GE T VOD]

    symbols = (held + named + spaced + us).map(&:strip).uniq
    puts "symbols: #{symbols.size} (held=#{held.size} named=#{named.size} " \
         "spaced=#{spaced.size} us=#{us.size})"

    rows = []
    failures = 0

    symbols.each_with_index do |symbol, i|
      sleep PACE unless i.zero?
      print "\r#{i + 1}/#{symbols.size} #{symbol.ljust(14)}"

      begin
        body = adapter.send(:get_json, "/v8/finance/chart/#{symbol}",
                            period1: 0, period2: Time.now.to_i, interval: "1d",
                            events: "div,split", includeAdjustedClose: "false")
        result = Array(body.dig("chart", "result")).first
        next failures += 1 if result.nil?

        offset = result.dig("meta", "gmtoffset").to_i
        stamps = result["timestamp"] || []
        quote = (result.dig("indicators", "quote") || []).first || {}
        closes = quote["close"] || []

        # Yahoo's OWN ADJUSTED closes by date — the evidence the classifier reads.
        series = {}
        stamps.each_with_index do |ts, idx|
          next if closes[idx].nil?

          series[Time.at(ts.to_i + offset).utc.to_date] = closes[idx].to_f
        end
        dates = series.keys.sort

        divs = (result.dig("events", "dividends") || {}).values.to_h do |ev|
          [ Time.at(ev["date"].to_i + offset).utc.to_date, ev["amount"].to_f ]
        end

        (result.dig("events", "splits") || {}).each_value do |ev|
          ex = Time.at(ev["date"].to_i + offset).utc.to_date
          num = ev["numerator"].to_f
          den = ev["denominator"].to_f
          next if num <= 0 || den <= 0

          before = dates.reverse_each.find { |d| d < ex }
          after = dates.find { |d| d >= ex }

          rows << {
            symbol:, currency: result.dig("meta", "currency"),
            exchange: result.dig("meta", "exchangeName"),
            ex_date: ex, num:, den:, ratio: num / den,
            before_date: before, after_date: after,
            before_close: before && series[before], after_close: after && series[after],
            div_on_ex: divs[ex]
          }
        end
      rescue StandardError
        failures += 1
      end
    end

    puts "\nfactors: #{rows.size} across #{rows.map { |r| r[:symbol] }.uniq.size} symbols " \
         "(#{failures} symbols unavailable)"

    CSV.open(Rails.root.join(CSV_PATH), "w") do |csv|
      csv << rows.first.keys if rows.any?
      rows.each { |r| csv << r.values }
    end
    puts "wrote #{CSV_PATH}"
  end

  desc "Score PriceProvider::Yahoo's shipped classifier against the collected factors"
  task score_factors: :environment do
    require "csv"

    path = Rails.root.join(CSV_PATH)
    abort "#{CSV_PATH} not found — run bin/rails yahoo:collect_factors first" unless path.exist?

    # Independently-known truth: public corporate actions, plus every factor named
    # in any of #66's three rejected gate rounds. Kept small and citable on purpose
    # — it is the scoring key, so it must not be a product of the rule.
    truth = {
      %w[HMMC.TO 2023-01-04] => :share, %w[VTI.CN 2026-05-22] => :share,
      %w[VTI.CN 2026-05-27] => :share,  %w[XCS.TO 2021-12-30] => :price,
      %w[XCS.TO 2025-12-30] => :price,  %w[LUG.TO 1997-11-03] => :share,
      %w[WCN.TO 2016-06-01] => :share,  %w[WKHS 2025-03-17] => :share,
      %w[GOOG 2014-03-27] => :share,    %w[TRP.TO 2024-10-02] => :price,
      %w[BN.TO 2022-12-12] => :price,   %w[BN.TO 2013-04-15] => :price,
      %w[ZEQT.TO 2025-12-30] => :price, %w[ZEQT.TO 2025-08-18] => :share,
      %w[VDY.TO 2024-12-30] => :price,  %w[VDY.TO 2025-12-30] => :price,
      %w[GE 2019-02-26] => :price,      %w[F 2000-06-29] => :price,
      %w[FTN.TO 2025-09-26] => :share,  %w[FTN.TO 2025-12-16] => :share,
      %w[FTN.TO 2026-05-19] => :share,  %w[LCS.TO 2024-12-17] => :share,
      %w[LCS.TO 2026-06-25] => :share,  %w[LCS.TO 2026-01-27] => :share,
      %w[AAPL 2020-08-31] => :share,    %w[AAPL 2014-06-09] => :share,
      %w[TSLA 2020-08-31] => :share,    %w[TSLA 2022-08-25] => :share,
      %w[NVDA 2024-06-10] => :share,    %w[AMZN 2022-06-06] => :share,
      %w[GOOG 2022-07-18] => :share,    %w[SHOP.TO 2022-06-29] => :share,
      %w[GE 2021-08-02] => :share,      %w[WKHS 2024-06-17] => :share,
      %w[WKHS 2025-12-08] => :share
    }

    adapter = PriceProvider::Yahoo.new
    rows = CSV.read(path, headers: true).map(&:to_h)
             .uniq { |r| [ r["symbol"], r["ex_date"], r["num"], r["den"] ] }

    verdicts = Hash.new(0)
    in_band = Hash.new(0)
    correct = 0
    wrong = []
    close_calls = []
    suppressed_outside_band = []

    rows.each do |r|
      num = BigDecimal(r["num"])
      den = BigDecimal(r["den"])
      ratio = (num / den).round(PriceProvider::Yahoo::RATIO_SCALE)
      next if ratio == 1

      factor = PriceProvider::Factor.new(ex_date: Date.parse(r["ex_date"]), ratio:,
                                         numerator: num, denominator: den)
      closes = {}
      closes[Date.parse(r["before_date"])] = BigDecimal(r["before_close"]) if r["before_close"].present?
      closes[Date.parse(r["after_date"])] = BigDecimal(r["after_close"]) if r["after_close"].present?

      share, reason = adapter.send(:share_count_event?, factor, closes, closes.keys.sort)
      got = share ? :share : :price
      verdicts[got] += 1

      band = PriceProvider::Yahoo::NEAR_ONE_BAND.cover?(ratio)
      in_band[got] += 1 if band
      suppressed_outside_band << "#{r['symbol']} #{r['ex_date']} #{factor.label}" if !share && !band
      close_calls << "#{r['symbol']} #{r['ex_date']} #{factor.label}" if reason&.include?("CLOSE CALL")

      want = truth[[ r["symbol"], r["ex_date"] ]]
      next if want.nil?

      if got == want
        correct += 1
      else
        wrong << "#{r['symbol']} #{r['ex_date']} #{factor.label} want=#{want} got=#{got} :: #{reason}"
      end
    end

    puts "factors: #{rows.size} across #{rows.map { |r| r['symbol'] }.uniq.size} symbols"
    puts "verdicts: #{verdicts.inspect}"
    puts "in-band:  #{in_band.inspect}   (the band is where a price-only action is possible at all)"
    puts "scored:   #{correct} correct / #{wrong.size} wrong, of #{correct + wrong.size} known"
    wrong.each { |w| puts "  MISS #{w}" }
    puts "close calls: #{close_calls.size}"
    close_calls.first(20).each { |c| puts "  #{c}" }
    puts "suppressed OUTSIDE the band (must be 0): #{suppressed_outside_band.size}"
    suppressed_outside_band.each { |s| puts "  #{s}" }
  end
end
