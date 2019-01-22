#! /usr/bin/env ruby

# frozen_string_literal: true

require 'csv'
require 'nokogiri'
require 'open-uri'
require 'uri'

MINUTES_LATE_PATTERN = 'received credits for trips taking (\d+) minutes or more than expected'

BASE_URL = 'https://www.wmata.com'
base_report_list_url = URI.join(BASE_URL, '/service/daily-report/list.cfm')

# Start with the current month and year, and work backwards.
# Eventually, the reports will no longer have the "Rush Hour
# Promise" header, and we'll stop scraping then.
month = Time.now.month
year = Time.now.year

# Keep track of how many consecutive non-weekend days have
# missed Promise information. If enough occur in a row, we
# can assume that we've found the moment in time that the
# Promise data began, in early 2018.
weekdays_without_promise_info = 0
POSSIBLE_CONSECUTIVE_HOLIDAYS = 2
end_of_promise_information_found = false

# Set up a short delay between iterations, to avoid
# overloading the web server
SECONDS_BETWEEN_REQUESTS = 0.5

promise_data = []

until end_of_promise_information_found
  report_list_url = "#{base_report_list_url}?currentmonth=#{month}&currentyear=#{year}"
  report_list_doc = Nokogiri::HTML(URI.open(report_list_url))
  report_links = report_list_doc.xpath("//h3[contains(text(), '#{year}')]/parent::div/a")

  report_links.each do |link|
    report_date = Date.parse(link.text.strip)

    # The Rush Hour Promise doesn't apply on weekends.
    # Later on, we will also skip holidays.
    case report_date.wday
    when 6
      puts "#{report_date}: Ignoring a Saturday"
      next
    when 0
      puts "#{report_date}: Ignoring a Sunday"
      next
    end

    sleep(SECONDS_BETWEEN_REQUESTS)

    # Need to make URL absolute instead of relative
    report_url = URI.join(BASE_URL, link['href'])
    report_doc = Nokogiri::HTML(URI.open(report_url))

    if report_doc.css('.content')[0].text.include? 'Due to the severe weather event, the Rush Hour Promise was not in effect.'
      puts "#{report_date}: Ignoring a day with severe weather"
      next
    end

    promise_title = report_doc.xpath('//strong[contains(text(), "Rush Hour Promise")]')

    if promise_title.length == 1
      weekdays_without_promise_info = 0
    elsif weekdays_without_promise_info + 1 > POSSIBLE_CONSECUTIVE_HOLIDAYS
      puts "#{report_date}: Found the end of Rush Hour Promise data"
      end_of_promise_information_found = true
      break
    else
      puts "#{report_date}: Ignoring a holiday"
      weekdays_without_promise_info += 1
      next
    end

    promise_element = promise_title[0].parent.parent
    raise 'WMATA webpage structure has changed; scraper needs updating' unless promise_element.xpath('./*/strong').length == 4

    on_time_text = promise_element.xpath('./*/strong')[1].text.strip
    less_than_5_minutes_late_text = promise_element.xpath('./*/strong')[2].text.strip
    received_credit_text = promise_element.xpath('./*/strong')[3].text.strip
    puts "#{report_date}: on-time #{on_time_text}, <5 mins late #{less_than_5_minutes_late_text}, #{received_credit_text} received credit"

    promise_text = promise_element.text.gsub(/\s+/, ' ').strip
    minutes_late_to_receive_credit = Integer(promise_text.match(MINUTES_LATE_PATTERN)[1])

    promise_info = {
      date: report_date,
      # Using `BigDecimal` is more correct, but less simple
      # to serialize into a CSV document; `round`ing `Float`s
      # will yield an equivalent result here
      share_arrived_on_time: (Float(on_time_text.sub('%', '')) / 100).round(3),
      share_arrived_less_than_5_minutes_late: (Float(less_than_5_minutes_late_text.sub('%', '')) / 100).round(3),
      # Occasionally (eg, 2018-10-17), `.` is incorrectly
      # used instead of `,` as the thousands delimiter
      number_received_credit: Integer(received_credit_text.sub(/[\.,]/, '')),
      minutes_late_to_receive_credit: minutes_late_to_receive_credit
    }
    promise_data << promise_info
  end

  # Prepare to parse the previous month
  if month == 1
    year -= 1
    month = 12
  else
    month -= 1
  end
end

CSV.open('./rush_hour_promise.csv', 'w') do |csv|
  csv << promise_data.first.keys
  promise_data.each do |datum|
    csv << datum.values
  end
end
