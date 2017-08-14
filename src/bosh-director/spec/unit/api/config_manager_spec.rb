require 'spec_helper'

describe Bosh::Director::Api::ConfigManager do
  subject(:manager) { Bosh::Director::Api::ConfigManager.new }
  let(:valid_yaml) { YAML.dump("---\n{key: value") }
  let(:type) { 'my-type' }
  let(:name) { 'some-name' }

  describe '#create' do
    it 'saves the config' do
      expect {
        manager.create(type, name, valid_yaml)
      }.to change(Bosh::Director::Models::Config, :count).from(0).to(1)

      config = Bosh::Director::Models::Config.first
      expect(config.created_at).to_not be_nil
      expect(config.content).to eq(valid_yaml)
    end
  end

  describe '#find' do
    before do
      Bosh::Director::Models::Config.make(type: 'my-type', name: 'my-name')
      Bosh::Director::Models::Config.make(type: 'new-type', name: 'new-name')
      Bosh::Director::Models::Config.make(type: 'my-type', name: 'other-name')
      Bosh::Director::Models::Config.make(type: 'new-type', name: 'new-name', content: 'newer-content')
    end

    context "when 'latest' is anything but string 'true'" do
      context 'when no filtering' do
        it 'returns all configs including outdated ones' do
          configs = manager.find
          expect(configs.count).to eq(4)
          expect(configs).to include(Bosh::Director::Models::Config.all[0])
          expect(configs).to include(Bosh::Director::Models::Config.all[1])
          expect(configs).to include(Bosh::Director::Models::Config.all[2])
          expect(configs).to include(Bosh::Director::Models::Config.all[3])
        end

        it 'sorts type -> name -> id' do
          Bosh::Director::Models::Config.make(type: 'new-type', name: 'new-name', content: 'newer-content2')

          configs = manager.find

          expect(configs[2].content).to eq('newer-content2')
          expect(configs[3].content).to eq('newer-content')
          expect(configs[4].content).to eq(nil)
        end
      end

      context 'when filtering' do
        it 'returns only the elements with the given type' do
          configs = manager.find(type: 'my-type')
          expect(configs.count).to eq(2)
        end

        it 'returns only the elements with the given name' do
          configs = manager.find(name: 'other-name')
          expect(configs.count).to eq(1)
        end

        it 'returns only the elements matching type and name' do
          configs = manager.find(name: 'new-name', type: 'new-type')
          expect(configs.count).to eq(2)
        end

        it 'returns no elements with no matches' do
          configs = manager.find(type: 'foo', name: 'bar')
          expect(configs.count).to eq(0)
        end
      end
    end

    context "when 'latest' is string 'true'" do
      context 'when no filtering' do
        it 'returns the latest config for each type/name combination' do
          configs = manager.find(latest: 'true')
          expect(configs.count).to eq(3)
          expect(configs).to include(Bosh::Director::Models::Config.all[0])
          expect(configs).to include(Bosh::Director::Models::Config.all[2])
          expect(configs).to include(Bosh::Director::Models::Config.all[3])
        end
      end

      context 'when filtering' do
        it 'returns only the elements with the given type' do
          configs = manager.find(type: 'my-type', latest: 'true')
          expect(configs.count).to eq(2)
        end

        it 'returns only the elements with the given name' do
          configs = manager.find(name: 'other-name', latest: 'true')
          expect(configs.count).to eq(1)
        end

        it 'returns only the elements matching type and name' do
          configs = manager.find(name: 'new-name', type: 'new-type', latest: 'true')
          expect(configs.count).to eq(1)
        end

        it 'returns no elements with no matches' do
          configs = manager.find(type: 'foo', name: 'bar', latest: 'true')
          expect(configs.count).to eq(0)
        end
      end

      context 'when configs have been deleted' do
        it 'returns only not deleted configs' do
          Bosh::Director::Models::Config.make(type: 'my-type', name: 'my-name', deleted: true)

          configs = manager.find(type: 'my-type', name: 'my-name')

          expect(configs.count).to eq(1)
        end
      end
    end
  end

  describe '#delete' do
    context 'when config entry exists' do
      it "sets deleted to 'true'" do
        Bosh::Director::Models::Config.make(type: 'my-type', name: 'my-name')

        count = manager.delete('my-type', 'my-name')

        expect(count).to eq(1)

        configs = Bosh::Director::Models::Config.where(type: 'my-type', name: 'my-name')

        expect(configs.count).to eq(1)
        expect(configs.first.deleted).to eq(true)
      end
    end

    context 'when multiple config entries exist' do
      it "sets deleted to all matching configs to 'true'" do
        Bosh::Director::Models::Config.make(type: 'my-type', name: 'my-name')
        Bosh::Director::Models::Config.make(type: 'my-type', name: 'my-name')
        Bosh::Director::Models::Config.make(type: 'other-type', name: 'other-name')

        count = manager.delete('my-type', 'my-name')

        expect(count).to eq(2)

        configs = Bosh::Director::Models::Config.where(type: 'my-type', name: 'my-name')

        expect(configs.map(:deleted)).to all(eq(true))

        configs = Bosh::Director::Models::Config.where(type: 'other-type', name: 'other-name')

        expect(configs.first.deleted).to eq(false)
      end

      it "does not delete a deleted config again" do
        Bosh::Director::Models::Config.make(type: 'my-type', name: 'my-name', deleted: true)
        Bosh::Director::Models::Config.make(type: 'my-type', name: 'my-name')

        count = manager.delete('my-type', 'my-name')

        expect(count).to eq(1)
      end
    end

    context 'when the configs table is empty' do
      it 'does not crash' do
        count = manager.delete('my-type', 'my-name')

        expect(count).to eq(0)
      end
    end
  end
end
