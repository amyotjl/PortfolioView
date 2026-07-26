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
        return HoldingsCsvParser if holdings_csv?

        raise UnreadableFile,
              "must be a PortfolioView JSON export or a broker holdings CSV " \
              "(expected a JSON object, or a header row with #{HoldingsCsvParser::REQUIRED_HEADERS.join(', ')})"
      end

      private

      def json?
        @body.lstrip.start_with?("{")
      end

      def holdings_csv?
        header = @body.lines.find { |line| line.strip.present? }
        return false if header.nil?

        # Compare on the parsed header row so quoted headers containing commas
        # ("Book Value (CAD)") are matched correctly.
        fields = CSV.parse_line(header, liberal_parsing: true)&.compact&.map { |f| f.to_s.strip } || []
        HoldingsCsvParser::REQUIRED_HEADERS.all? { |required| fields.include?(required) }
      rescue CSV::MalformedCSVError
        false
      end
    end
  end
end
