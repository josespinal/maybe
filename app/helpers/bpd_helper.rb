module BpdHelper
  require "nokogiri"

  def parse_email_content(body_html)
    # Parse the email HTML
    doc = Nokogiri::HTML(body_html)

    # Extract the table with class "myTable2"
    table = doc.at_css("table.myTable2")
    return {} unless table

    # Extract headers (inside <th> tags)
    headers = table.css("th").map(&:text).map(&:strip)

    # Extract rows (inside <td> tags)
    rows = table.css("tr")[1..] # Skip the header row
    structured_data = rows.map do |row|
      cells = row.css("td").map(&:text).map(&:strip)
      headers.zip(cells).to_h
    end

    # Process the transaction
    transaction = structured_data.first

    # Parse "Monto" as money (convert to cents)
    if transaction["Monto"]
      transaction["Moneda"] =
      if transaction["Monto"].include?("RD$")
        "DOP"
      elsif transaction["Monto"].include?("US$")
        "USD"
      elsif transaction["Monto"].include?("EUR$")
        "EUR"
      else
        "Unknown"
      end

      # Remove currency symbols and commas, and convert to cents
      transaction["Monto"] = transaction["Monto"].gsub(/[^\d.]/, "").to_f
    end

    # Extract card type and last 4 digits
    card_info = extract_card_info(doc)
    transaction.merge!(card_info)

    transaction
  end

  private

    # Extract card type and last 4 digits
    def extract_card_info(doc)
      card_text = doc.at_css('p:contains("Gracias por utilizar su")')&.text
      return {} unless card_text

      match = card_text.match(/Gracias por utilizar su ([A-Z\s]+), terminada en\s+(\d{4})/)
      {

        "Card Type" => match[1]&.strip,
        "Last 4 Digits" => match[2]&.strip
      }
    end

    # Save a transaction to the database
    def save_transaction(transaction, email)
      Transaction.create!(
        amount: Money.new(transaction["Monto"], transaction["Moneda"]),
        type: transaction["Estatus"],
        currency: transaction["Moneda"],
        date_posted: transaction["Fecha"],
        time_posted: email.date.strftime("%H:%M:%S"),
        merchant_name: transaction["Comercio"],
        card_type: transaction["Card Type"],
        last_4_digits: transaction["Last 4 Digits"],
        notes: transaction["Estatus"]
      )
    end
end
