#
# Copyright:: Copyright (c) Chef Software Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require_relative "../resource"
require_relative "../dist"

class Chef
  class Resource
    class ChefClientScheduledTask < Chef::Resource
      unified_mode true

      provides :chef_client_scheduled_task

      description "Use the chef_client_cron resource to setup the #{Chef::Dist::PRODUCT} to run as a Windows scheduled task. This resource will also create the specified log directory if it doesn't already exist."
      introduced "16.0"
      examples <<~DOC
      Setup #{Chef::Dist::PRODUCT} to run using the default 30 minute cadence
      ```ruby
        chef_client_scheduled_task "Run chef-client as a scheduled task"
      ```

      Run #{Chef::Dist::PRODUCT} on system start
      ```ruby
        chef_client_scheduled_task 'Chef Client on start' do
          frequency 'onstart'
        end
      ```

      Run #{Chef::Dist::PRODUCT} with extra options passed to the client
      ```ruby
        chef_client_scheduled_task "Run an override recipe" do
          daemon_options ["--override-runlist mycorp_base::default"]
        end
      ```
      DOC

      resource_name :chef_client_scheduled_task

      property :task_name, String,
        description: "The name of the scheduled task to create.",
        default: Chef::Dist::CLIENT

      property :user, String,
        description: "The name of the user that #{Chef::Dist::PRODUCT} runs as.",
        default: "System", sensitive: true

      property :password, String, sensitive: true,
        description: "The password for the user that #{Chef::Dist::PRODUCT} runs as."

      property :frequency, String,
        description: "Frequency with which to run the task.",
        default: "minute",
        equal_to: %w{minute hourly daily monthly once on_logon onstart on_idle}

      property :frequency_modifier, [Integer, String],
        coerce: proc { |x| Integer(x) },
        callbacks: { "should be a positive number" => proc { |v| v > 0 } },
        description: "Numeric value to go with the scheduled task frequency",
        default: 30

      property :accept_chef_license, [true, false],
        description: "Accept the Chef Online Master License and Services Agreement. See https://www.chef.io/online-master-agreement/",
        default: false

      property :start_date, String,
        description: "The start date for the task in m:d:Y format (ex: 12/17/2020).",
        regex: [%r{^[0-1][0-9]\/[0-3][0-9]\/\d{4}$}]

      property :start_time, String,
        description: "The start time for the task in HH:mm format (ex: 14:00). If the frequency is minute default start time will be Time.now plus the frequency_modifier number of minutes.",
        regex: [/^\d{2}:\d{2}$/]

      property :splay, [Integer, String],
        coerce: proc { |x| Integer(x) },
        callbacks: { "should be a positive number" => proc { |v| v > 0 } },
        description: "A random number of seconds between 0 and X to add to interval so that all #{Chef::Dist::CLIENT} commands don't execute at the same time.",
        default: 300

      property :run_on_battery, [true, false],
        description: "Run the #{Chef::Dist::PRODUCT} task when the system is on batteries.",
        default: true

      property :config_directory, String,
        description: "The path of the config directory.",
        default: Chef::Dist::CONF_DIR

      property :log_directory, String,
        description: "The path of the directory to create the log file in.",
        default: lazy { |r| "#{r.config_directory}/log" }

      property :log_file_name, String,
        description: "The name of the log file to use.",
        default: "client.log"

      property :chef_binary_path, String,
        description: "The path to the #{Chef::Dist::CLIENT} binary.",
        default: "C:/#{Chef::Dist::LEGACY_CONF_DIR}/#{Chef::Dist::DIR_SUFFIX}/bin/#{Chef::Dist::CLIENT}"

      property :daemon_options, Array,
        description: "An array of options to pass to the #{Chef::Dist::CLIENT} command.",
        default: lazy { [] }

      action :add do
        # TODO: Replace this with a :create_if_missing action on directory when that exists
        unless Dir.exist?(new_resource.log_directory)
          directory new_resource.log_directory do
            inherits true
            recursive true
            action :create
          end
        end

        # According to https://docs.microsoft.com/en-us/windows/desktop/taskschd/schtasks,
        # the :once, :onstart, :onlogon, and :onidle schedules don't accept schedule modifiers
        windows_task new_resource.task_name do
          run_level                      :highest
          command                        full_command
          user                           new_resource.user
          password                       new_resource.password
          frequency                      new_resource.frequency.to_sym
          frequency_modifier             new_resource.frequency_modifier if frequency_supports_frequency_modifier?
          start_time                     new_resource.start_time
          start_day                      new_resource.start_date unless new_resource.start_date.nil?
          random_delay                   new_resource.splay if frequency_supports_random_delay?
          disallow_start_if_on_batteries new_resource.splay unless new_resource.run_on_battery
          action                         %i{create enable}
        end
      end

      action :remove do
        windows_task new_resource.task_name do
          action :delete
        end
      end

      action_class do
        #
        # The full command to run in the scheduled task
        #
        # @return [String]
        #
        def full_command
          # Fetch path of cmd.exe through environment variable comspec
          cmd_path = ENV["COMSPEC"]

          "#{cmd_path} /c \'#{client_cmd}\'"
        end

        # Build command line to pass to cmd.exe
        #
        # @return [String]
        def client_cmd
          cmd = new_resource.chef_binary_path.dup
          cmd << " -L #{::File.join(new_resource.log_directory, new_resource.log_file_name)}"
          cmd << " -c #{::File.join(new_resource.config_directory, "client.rb")}"

          # Add custom options
          cmd << " #{new_resource.daemon_options.join(" ")}" if new_resource.daemon_options.any?
          cmd << " --chef-license accept" if new_resource.accept_chef_license
          cmd
        end

        #
        # not all frequencies in the windows_task resource support random_delay
        #
        # @return [boolean]
        #
        def frequency_supports_random_delay?
          %w{once minute hourly daily weekly monthly}.include?(new_resource.frequency)
        end

        #
        # not all frequencies in the windows_task resource support frequency_modifier
        #
        # @return [boolean]
        #
        def frequency_supports_frequency_modifier?
          # these are the only ones that don't
          !%w{once on_logon onstart on_idle}.include?(new_resource.frequency)
        end
      end
    end
  end
end
