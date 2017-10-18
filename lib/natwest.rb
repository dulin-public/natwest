# coding: utf-8
require 'mechanize'
require 'awesome_print'
require 'yaml'

module Kernel
  def assert(condition, message)
    raise message unless condition
  end
end

module Natwest
  URL = 'https://www.nwolb.com/'

  module Login
    attr_reader :ua, :pin
    attr_accessor :password, :pin, :customer_number

    def credential_load
      config = File.expand_path("~/.natwest.yaml")

      if File.exists?(config)
        if File.world_readable?(config) or not File.owned?(config)
          mode = File.stat(config).mode.to_s(8)
          $stderr.puts "#{config}: Insecure permissions: #{mode}"
        end
      end

      credentials = YAML.load(File.read(config)) rescue {}

      ['customer number', 'PIN', 'password'].each do |credential|
        key = credential.tr(' ','_').downcase.to_sym
        next if credentials.key?(key)
        unless $stdin.tty? and $stdout.tty?
          $stderr.puts "Can't prompt for credentials; STDIN or STDOUT is not a TTY"
          endxit(1)
        end

        credentials[key] = ask("Please enter your #{credential}:") do |q|
          q.echo = "*"
        end
      end

      return credentials
    end

    def logged_in?
      @logged_in ||= false
    end

    def login
      credentials = credential_load
      credentials.each_pair{|name, value| send("#{name}=".to_sym, value)}
      enter_customer_number
      enter_pin_and_password
      @logged_in = true
    end

    private
    def enter_customer_number
      login_form = ua.get(URL).frames.first.click.forms.first
      login_form['ctl00$mainContent$LI5TABA$CustomerNumber_edit'] = customer_number
      self.page = login_form.submit
      assert(page.title.include?('PIN and password details'),
             "Got '#{page.title}' instead of PIN/Password prompt")
    end

    def enter_pin_and_password
      expected = expected('PIN','number') + expected('Password','character')
      self.page = page.forms.first.tap do |form|
       ('A'..'F').map do |letter|
         "ctl00$mainContent$Tab1$LI6PPE#{letter}_edit"
        end.zip(expected).each {|field, value| form[field] = value}
      end.submit
      assert(page.title.include?('Account summary'),
             "Got '#{page.title}' instead of accounts summary")
    end

    def expected(credential, type)
      page.body.
           scan(/Enter the (\d+)[a-z]{2} #{type}/).
           flatten.map{|i| i.to_i - 1}.tap do |indices|
        assert(indices.uniq.size == 3,
               "Unexpected #{credential} characters requested")
        characters = [*send(credential.downcase.to_sym).to_s.chars]
        indices.map! {|i| characters[i]}
      end
    end
  end

  class Customer
    include Login
    NO_DETAILS = 'No further transaction details held'
    attr_accessor :page

    def initialize
      @ua = Mechanize.new

      ua.user_agent_alias = 'Windows IE 7'
      ua.verify_mode = 0
      ua.pluggable_parser.default = Mechanize::Download
    end

    def accounts
      page.parser.css('table.AccountTable > tbody > tr').each_slice(2).map do |meta, statement|
        Account.new.tap do |acc|
          acc.name = meta.at('span.AccountName').inner_text
          acc.number = meta.at('span.AccountNumber').inner_text.gsub(/[^\d]/,'')
          acc.sort_code = meta.at('span.SortCode').inner_text.gsub(/[^\d-]/,'')
          acc.balance = meta.css('td')[-2].inner_text
          acc.available = meta.css('td')[-1].inner_text
          acc.transactions =
            statement.css('table.InnerAccountTable > tbody > tr').map do |tr|
            transaction = Hash[[:date, :details, :credit, :debit].
              zip((cells = tr.css('td')).map(&:inner_text))]
            unless (further = cells[1]['title']) == NO_DETAILS
              transaction[:details] += " (#{further.squeeze(' ')})"
            end
            Hash[transaction.map{|k,v| [k, v == ' - ' ? nil : v]}]
          end
        end
      end
    end

    def statement
      self.page = page.link_with(text: 'Statements').click
      assert(page.title.include?('Statements'),
             "Got '#{page.title}' instead of Statements")

      self.page = page.link_with(text: 'Download/export transactions').click
      assert(page.title.include?('Transactions – Download transactions – Select account and period'),
             "Got '#{page.title}' instead of Transactions – Download transactions – Select account and period")

      form = page.form_with(action: './StatementsDownloadFixedPeriod.aspx')
      form.field_with(name: 'ctl00$mainContent$SS6SPDDA').option_with(text: 'Last week').select
      form.field_with(name: 'ctl00$mainContent$SS6SDDDA').option_with(text: 'Microsoft Excel, Lotus 123, Text (CSV file)').select
      self.page = form.click_button

      assert(page.title.include?('Transactions – Download transactions – Download'),
             "Got '#{page.title}' instead of Transactions – Download transactions – Download")

      form = page.form_with(action: './StatementsDownloadFixedPeriod.aspx')
      button = form.button_with(value: 'Download transactions')
      self.page = form.submit(button)

      return page.body

    end

  end

  class Account
    attr_accessor :name, :number, :sort_code, :balance, :available, :transactions
  end
end
