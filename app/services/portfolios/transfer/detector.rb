module Portfolios
  module Transfer
    # Picks a parser from the file's CONTENT, not its name or MIME type — a
    # browser reports whatever the OS guessed, and users rename files.
    class Detector
      def self.call(...) = new(...).call

      def initialize(body)
        @body = body
      end

      def parser
        return NativeParser if json?
        # Activities before holdings: an activity LEDGER is strictly richer than a
        # holdings SNAPSHOT (real trade dates and closed positions), so if a file
        # could somehow satisfy both header sets, the ledger reading wins.
        return ActivitiesCsvParser if csv_with_headers?(ActivitiesCsvParser::REQUIRED_HEADERS)
        return HoldingsCsvParser if csv_with_headers?(HoldingsCsvParser::REQUIRED_HEADERS)

        raise UnreadableFile,
              "must be a PortfolioView JSON export, a broker activity ledger CSV, or a broker " \
              "holdings CSV (expected a JSON object, or a header row with " \
              "#{ActivitiesCsvParser::REQUIRED_HEADERS.join(', ')} " \
              "or #{HoldingsCsvParser::REQUIRED_HEADERS.join(', ')})"
      end

      private

      def json?
        @body.lstrip.start_with?("{")
      end

      def csv_with_headers?(required)
        required.all? { |header| header_fields.include?(header) }
      end

      # Compare on the PARSED header row so quoted headers containing commas
      # ("Book Value (CAD)") are matched correctly.
      def header_fields
        @header_fields ||= begin
          header = @body.lines.find { |line| line.strip.present? }
          if header.nil?
            []
          else
            CSV.parse_line(header, liberal_parsing: true)&.compact&.map { |f| f.to_s.strip } || []
          end
        rescue CSV::MalformedCSVError
          []
        end
      end
    end
  end
end
