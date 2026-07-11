# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# Curated benchmark list (PLAN.md § Database schema, backlog #004).
# Idempotent: instruments are looked up case-insensitively via the
# upper(symbol) identity; benchmarks are keyed on instrument_id.
[
  { symbol: "SPY", instrument_name: "SPDR S&P 500 ETF Trust",          benchmark_name: "S&P 500 (SPY)" },
  { symbol: "VTI", instrument_name: "Vanguard Total Stock Market ETF", benchmark_name: "Total US Stock Market (VTI)" },
  { symbol: "QQQ", instrument_name: "Invesco QQQ Trust",               benchmark_name: "Nasdaq-100 (QQQ)" }
].each do |seed|
  instrument = Instrument.find_by("upper(symbol) = ?", seed[:symbol]) ||
               Instrument.create!(symbol: seed[:symbol],
                                  name: seed[:instrument_name],
                                  instrument_type: "etf",
                                  currency: "USD")

  Benchmark.find_or_initialize_by(instrument_id: instrument.id)
           .update!(name: seed[:benchmark_name])
end
