# Demo data for the README screenshots (and for a quick look at a populated UI
# on a fresh checkout). See lib/demo/seeder.rb for the design; the short version
# is that every trade is priced from the real daily_prices row for its date, so
# the charts show real market history rather than invented numbers.
namespace :demo do
  desc "Create the instruments the demo account trades (enqueues price backfill + metadata)"
  task instruments: :environment do
    require Rails.root.join("lib/demo/instruments")
    Demo::Instruments.call
  end

  desc "Seed the demo user (#{"demo@portfolioview.app"}) with three portfolios of real-priced trades"
  task seed: :environment do
    require Rails.root.join("lib/demo/seeder")
    Demo::Seeder.call
  end
end
