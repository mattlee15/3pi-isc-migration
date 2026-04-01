#!/usr/bin/env ruby
require 'csv'
require_relative 'common'

# Create configs directory if it doesn't exist
Dir.mkdir('configs') unless Dir.exist?('configs')

configs = [
  'env/LOYALTY_V1_LOYALTY_CARD_SERVICE_CONFIGURATIONS_CAPER_TEST_WAREHOUSE',
  'env/LOYALTY_V1_LOYALTY_CARD_SERVICE_CONFIGURATIONS_CVS',
  'env/LOYALTY_V1_LOYALTY_CARD_SERVICE_CONFIGURATIONS_FRESH_GROCERY',
  'env/LOYALTY_V1_LOYALTY_CARD_SERVICE_CONFIGURATIONS_SAVEMART_V2',
  'env/LOYALTY_V1_LOYALTY_CARD_SERVICE_CONFIGURATIONS_THE_GARDEN'
]

csv_path = 'configs/loyalty_card_staging.csv'

CSV.open(csv_path, 'w') do |csv|
  csv << ['Config Name', 'RPC Staging', 'Migrated to Staging']

  configs.each do |config|
    csv << [config, 'Yes', 'No']
  end
end

puts "Created #{csv_path} with #{configs.length} configs"
puts "\nNext steps:"
puts "1. Run: ruby scripts/main.rb"
puts "2. Select mode for migration"
puts "3. Process staging configs only"
