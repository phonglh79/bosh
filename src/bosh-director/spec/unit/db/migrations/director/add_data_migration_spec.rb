require 'db_spec_helper'

module Bosh::Director
  describe 'Reminder to add test covering db migration while data exist' do
    it 'should have written a test for latest migration script that was added' do
      latest_db_migration_file = DBSpecHelper.get_latest_migration_script

      # This is an explicit reminder to write a test which covers migrating DB while it was already
      # populated with data. This test will fail every time a new migration script is added. Change
      # the file name below to the latest when a test is added.
      # Look at tests in this directory for similar examples: bosh-director/spec/unit/db/migrations/director
      expect(latest_db_migration_file).to eq('20170807144941_add_configs.rb')
    end
  end
end
