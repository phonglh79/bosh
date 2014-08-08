require 'spec_helper'
require 'rack/test'

module Bosh::Director
  module Api
    describe Controllers::DeploymentsController do
      include Rack::Test::Methods

      before { basic_authorize 'admin', 'admin' }

      let!(:temp_dir) { Dir.mktmpdir}

      before do
        blobstore_dir = File.join(temp_dir, 'blobstore')
        FileUtils.mkdir_p(blobstore_dir)

        test_config = Psych.load(spec_asset('test-director-config.yml'))
        test_config['dir'] = temp_dir
        test_config['blobstore'] = {
            'provider' => 'local',
            'options' => {'blobstore_path' => blobstore_dir}
        }
        test_config['snapshots']['enabled'] = true
        Config.configure(test_config)
        @director_app = App.new(Config.load_hash(test_config))
      end

      after do
        FileUtils.rm_rf(temp_dir)
      end

      def app
        @rack_app ||= described_class
      end

      it 'sets the date header' do
        get '/'
        last_response.headers['Date'].should_not be_nil
      end

      describe 'API calls' do
        describe 'creating a deployment' do
          it 'expects compressed deployment file' do
            post '/', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'only consumes text/yaml' do
            post '/', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/plain' }
            last_response.status.should == 404
          end
        end

        describe 'job management' do
          it 'allows putting jobs into different states' do
            Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            put '/foo/jobs/nats?state=stopped', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'allows putting job instances into different states' do
            Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            put '/foo/jobs/dea/2?state=stopped', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'allows putting the job instance into different resurrection_paused values' do
            deployment = Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            instance = Models::Instance.
                create(:deployment => deployment, :job => 'dea',
                       :index => '0', :state => 'started')
            put '/foo/jobs/dea/0/resurrection', Yajl::Encoder.encode('resurrection_paused' => true), { 'CONTENT_TYPE' => 'application/json' }
            last_response.status.should == 200
            expect(instance.reload.resurrection_paused).to be(true)
          end

          it "doesn't like invalid indices" do
            put '/foo/jobs/dea/zb?state=stopped', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            last_response.status.should == 400
          end

          it 'can get job information' do
            deployment = Models::Deployment.create(name: 'foo', manifest: Psych.dump({'foo' => 'bar'}))
            instance = Models::Instance.create(deployment: deployment, job: 'nats', index: '0', state: 'started')
            disk = Models::PersistentDisk.create(instance: instance, disk_cid: 'disk_cid')

            get '/foo/jobs/nats/0', {}

            last_response.status.should == 200
            expected = {
                'deployment' => 'foo',
                'job' => 'nats',
                'index' => 0,
                'state' => 'started',
                'disks' => %w[disk_cid]
            }

            Yajl::Parser.parse(last_response.body).should == expected
          end

          it 'should return 404 if the instance cannot be found' do
            get '/foo/jobs/nats/0', {}
            last_response.status.should == 404
          end
        end

        describe 'log management' do
          it 'allows fetching logs from a particular instance' do
            deployment = Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            instance = Models::Instance.
                create(:deployment => deployment, :job => 'nats',
                       :index => '0', :state => 'started')
            get '/foo/jobs/nats/0/logs', {}
            expect_redirect_to_queued_task(last_response)
          end

          it '404 if no instance' do
            get '/baz/jobs/nats/0/logs', {}
            last_response.status.should == 404
          end

          it '404 if no deployment' do
            deployment = Models::Deployment.
                create(:name => 'bar', :manifest => Psych.dump({'foo' => 'bar'}))
            get '/bar/jobs/nats/0/logs', {}
            last_response.status.should == 404
          end
        end

        describe 'listing deployments' do
          it 'has API call that returns a list of deployments in JSON' do
            num_dummies = Random.new.rand(3..7)
            stemcells = (1..num_dummies).map { |i|
              Models::Stemcell.create(
                  :name => "stemcell-#{i}", :version => i, :cid => rand(25000 * i))
            }
            releases = (1..num_dummies).map { |i|
              release = Models::Release.create(:name => "release-#{i}")
              Models::ReleaseVersion.create(:release => release, :version => i)
              release
            }
            deployments = (1..num_dummies).map { |i|
              d = Models::Deployment.create(:name => "deployment-#{i}")
              (0..rand(num_dummies)).each do |v|
                d.add_stemcell(stemcells[v])
                d.add_release_version(releases[v].versions.sample)
              end
              d
            }

            get '/', {}, {}
            last_response.status.should == 200

            body = Yajl::Parser.parse(last_response.body)
            body.kind_of?(Array).should be(true)
            body.size.should == num_dummies

            expected_collection = deployments.sort_by { |e| e.name }.map { |e|
              name = e.name
              releases = e.release_versions.map { |rv|
                Hash['name', rv.release.name, 'version', rv.version.to_s]
              }
              stemcells = e.stemcells.map { |sc|
                Hash['name', sc.name, 'version', sc.version]
              }
              Hash['name', name, 'releases', releases, 'stemcells', stemcells]
            }

            body.should == expected_collection
          end
        end

        describe 'getting deployment info' do
          it 'returns manifest' do
            deployment = Models::Deployment.
                create(:name => 'test_deployment',
                       :manifest => Psych.dump({'foo' => 'bar'}))
            get '/test_deployment'

            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)
            Psych.load(body['manifest']).should == {'foo' => 'bar'}
          end
        end

        describe 'getting deployment vms info' do
          it 'returns a list of agent_ids, jobs and indices' do
            deployment = Models::Deployment.
                create(:name => 'test_deployment',
                       :manifest => Psych.dump({'foo' => 'bar'}))
            vms = []

            15.times do |i|
              vm_params = {
                  'agent_id' => "agent-#{i}",
                  'cid' => "cid-#{i}",
                  'deployment_id' => deployment.id
              }
              vm = Models::Vm.create(vm_params)

              instance_params = {
                  'deployment_id' => deployment.id,
                  'vm_id' => vm.id,
                  'job' => "job-#{i}",
                  'index' => i,
                  'state' => 'started'
              }
              instance = Models::Instance.create(instance_params)
            end

            get '/test_deployment/vms'

            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)
            body.should be_kind_of Array
            body.size.should == 15

            15.times do |i|
              body[i].should == {
                  'agent_id' => "agent-#{i}",
                  'job' => "job-#{i}",
                  'index' => i,
                  'cid' => "cid-#{i}"
              }
            end
          end
        end

        describe 'deleting deployment' do
          it 'deletes the deployment' do
            deployment = Models::Deployment.create(:name => 'test_deployment', :manifest => Psych.dump({'foo' => 'bar'}))

            delete '/test_deployment'
            expect_redirect_to_queued_task(last_response)
          end
        end

        describe 'property management' do

          it 'REST API for creating, updating, getting and deleting ' +
                 'deployment properties' do

            deployment = Models::Deployment.make(:name => 'mycloud')

            get '/mycloud/properties/foo'
            last_response.status.should == 404

            get '/othercloud/properties/foo'
            last_response.status.should == 404

            post '/mycloud/properties', Yajl::Encoder.encode('name' => 'foo', 'value' => 'bar'), { 'CONTENT_TYPE' => 'application/json' }
            last_response.status.should == 204

            get '/mycloud/properties/foo'
            last_response.status.should == 200
            Yajl::Parser.parse(last_response.body)['value'].should == 'bar'

            get '/othercloud/properties/foo'
            last_response.status.should == 404

            put '/mycloud/properties/foo', Yajl::Encoder.encode('value' => 'baz'), { 'CONTENT_TYPE' => 'application/json' }
            last_response.status.should == 204

            get '/mycloud/properties/foo'
            Yajl::Parser.parse(last_response.body)['value'].should == 'baz'

            delete '/mycloud/properties/foo'
            last_response.status.should == 204

            get '/mycloud/properties/foo'
            last_response.status.should == 404
          end
        end

        describe 'problem management' do
          let!(:deployment) { Models::Deployment.make(:name => 'mycloud') }

          it 'exposes problem managent REST API' do
            get '/mycloud/problems'
            last_response.status.should == 200
            Yajl::Parser.parse(last_response.body).should == []

            post '/mycloud/scans'
            expect_redirect_to_queued_task(last_response)

            put '/mycloud/problems', Yajl::Encoder.encode('solutions' => { 42 => 'do_this', 43 => 'do_that', 44 => nil }), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)

            problem = Models::DeploymentProblem.
                create(:deployment_id => deployment.id, :resource_id => 2,
                       :type => 'test', :state => 'open', :data => {})

            put '/mycloud/problems', Yajl::Encoder.encode('solution' => 'default'), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'scans and fixes problems' do
            put '/mycloud/scan_and_fix', Yajl::Encoder.encode('jobs' => { 'job' => [0] }), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)
          end
        end

        describe 'snapshots' do
          before do
            deployment = Models::Deployment.make(name: 'mycloud')

            instance = Models::Instance.make(deployment: deployment, job: 'job', index: 0)
            disk = Models::PersistentDisk.make(disk_cid: 'disk0', instance: instance, active: true)
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap0a')

            instance = Models::Instance.make(deployment: deployment, job: 'job', index: 1)
            disk = Models::PersistentDisk.make(disk_cid: 'disk1', instance: instance, active: true)
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1a')
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1b')
          end

          describe 'creating' do
            it 'should create a snapshot for a job' do
              post '/mycloud/jobs/job/1/snapshots'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should create a snapshot for a deployment' do
              post '/mycloud/snapshots'
              expect_redirect_to_queued_task(last_response)
            end
          end

          describe 'deleting' do
            it 'should delete all snapshots of a deployment' do
              delete '/mycloud/snapshots'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should delete a snapshot' do
              delete '/mycloud/snapshots/snap1a'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should raise an error if the snapshot belongs to a different deployment' do
              snap = Models::Snapshot.make(snapshot_cid: 'snap2b')
              delete "/#{snap.persistent_disk.instance.deployment.name}/snapshots/snap2a"
              last_response.status.should == 400
            end
          end

          describe 'listing' do
            it 'should list all snapshots for a job' do
              get '/mycloud/jobs/job/0/snapshots'
              last_response.status.should == 200
            end

            it 'should list all snapshots for a deployment' do
              get '/mycloud/snapshots'
              last_response.status.should == 200
            end
          end
        end
      end

      describe 'POST', '/:deployment_name/errands/:name/runs' do
        before { Config.base_dir = Dir.mktmpdir }
        after { FileUtils.rm_rf(Config.base_dir) }

        def perform
          post(
            '/fake-dep-name/errands/fake-errand-name/runs',
            JSON.dump({}),
            { 'CONTENT_TYPE' => 'application/json' },
          )
        end

        it 'enqueues a RunErrand task' do
          job_queue = instance_double('Bosh::Director::JobQueue')
          allow(JobQueue).to receive(:new).and_return(job_queue)

          task = instance_double('Bosh::Director::Models::Task', id: 1)
          expect(job_queue).to receive(:enqueue).with(
            'admin',
            Jobs::RunErrand,
            'run errand fake-errand-name from deployment fake-dep-name',
            ['fake-dep-name', 'fake-errand-name'],
          ).and_return(task)

          perform
        end

        it 'returns a task' do
          perform
          expect_redirect_to_queued_task(last_response)
        end
      end
    end
  end
end
