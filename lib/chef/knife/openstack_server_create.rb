#
# Author:: Seth Chisamore (<schisamo@getchef.com>)
# Author:: Matt Ray (<matt@getchef.com>)
# Author:: Chirag Jog (<chirag@clogeny.com>)
# Copyright:: Copyright (c) 2011-2014 Chef Software, Inc.
# License:: Apache License, Version 2.0
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

require 'chef/knife/cloud/server/create_command'
require 'chef/knife/openstack_helpers'
require 'chef/knife/cloud/openstack_server_create_options'
require 'chef/knife/cloud/openstack_service'
require 'chef/knife/cloud/openstack_service_options'
require 'chef/knife/cloud/exceptions'

class Chef
  class Knife
    class Cloud
      class OpenstackServerCreate < ServerCreateCommand
        include OpenstackHelpers
        include OpenstackServerCreateOptions
        include OpenstackServiceOptions


        banner "knife openstack server create (options)"

        def before_exec_command
            # setup the create options
            @create_options = {
              :server_def => {
                #servers require a name, knife-cloud generates the chef_node_name
                :name => config[:chef_node_name],
                :image_ref => locate_config_value(:image),
                :flavor_ref => locate_config_value(:flavor),
                :security_groups => locate_config_value(:openstack_security_groups),
                :availability_zone => locate_config_value(:availability_zone),
                :metadata => locate_config_value(:metadata),
                :key_name => locate_config_value(:openstack_ssh_key_id)
              },
              :server_create_timeout => locate_config_value(:server_create_timeout)
            }

            @create_options[:server_def].merge!({:user_data => locate_config_value(:user_data)}) if locate_config_value(:user_data)
            @create_options[:server_def].merge!({:nics => locate_config_value(:network_ids).map { |nic| nic_id = { 'net_id' => nic }}}) if locate_config_value(:network_ids)

            Chef::Log.debug("Create server params - server_def = #{@create_options[:server_def]}")
            #set columns_with_info map
            @columns_with_info = [
            {:label => 'Instance ID', :key => 'id'},
            {:label => 'Name', :key => 'name'},
            {:label => 'Public IP', :key => 'addresses', :value_callback => method(:primary_public_ip_address)},
            {:label => 'Private IP', :key => 'addresses', :value_callback => method(:primary_private_ip_address)},
            {:label => 'Flavor', :key => 'flavor', :value_callback => method(:get_id)},
            {:label => 'Image', :key => 'image', :value_callback => method(:get_id)},
            {:label => 'Keypair', :key => 'key_name'},
            {:label => 'State', :key => 'state'},
            {:label => 'Availability Zone', :key => 'availability_zone'}
            ]
            super
        end

        def get_id(value)
          value['id']
        end

        # Setup the floating ip after server creation.
        def after_exec_command
          Chef::Log.debug("Addresses #{server.addresses}")
          msg_pair("Public IP Address", primary_public_ip_address(server.addresses)) if primary_public_ip_address(server.addresses)
          msg_pair("Private IP Address", primary_private_ip_address(server.addresses)) if primary_private_ip_address(server.addresses)

          floating_address = locate_config_value(:openstack_floating_ip)
          Chef::Log.debug("Floating IP Address requested #{floating_address}")
          unless (floating_address == '-1') #no floating IP requested
            addresses = service.connection.addresses
            #floating requested without value
            if floating_address.nil?
              free_floating = addresses.find_index {|a| a.fixed_ip.nil?}
              begin
                if free_floating.nil? #no free floating IP found
                  error_message = "Unable to assign a Floating IP from allocated IPs."
                  ui.fatal(error_message)
                  raise CloudExceptions::ServerSetupError, error_message
                else
                  floating_address = addresses[free_floating].ip
                end                
              rescue CloudExceptions::ServerSetupError => e
                cleanup_on_failure
                raise e
              end
            end
            server.associate_address(floating_address)
            #a bit of a hack, but server.reload takes a long time
            (server.addresses['public'] ||= []) << {"version"=>4,"addr"=>floating_address}
            msg_pair("Floating IP Address", floating_address)
          end

          Chef::Log.debug("Addresses #{server.addresses}")
          Chef::Log.debug("Public IP Address actual: #{primary_public_ip_address(server.addresses)}") if primary_public_ip_address(server.addresses)

          msg_pair("Private IP Address", primary_private_ip_address(server.addresses)) if primary_private_ip_address(server.addresses)
          super
        end

        def before_bootstrap
          super

          # Use SSH password either specified from command line or from openstack server instance
          config[:ssh_password] = locate_config_value(:ssh_password) || server.password unless config[:openstack_ssh_key_id]

          # private_network means bootstrap_network = 'private'
          config[:bootstrap_network] = 'private' if config[:private_network]

          # Which IP address to bootstrap
          unless config[:network] # --no-network
            bootstrap_ip_address = primary_public_ip_address(server.addresses) ||
              primary_private_ip_address(server.addresses) ||
              server.addresses.first
            Chef::Log.debug("No Bootstrap Network: #{config[:bootstrap_network]}")
          else
            bootstrap_ip_address = primary_network_ip_address(server.addresses, config[:bootstrap_network])
            Chef::Log.debug("Bootstrap Network: #{config[:bootstrap_network]}")
          end

          Chef::Log.debug("Bootstrap IP Address: #{bootstrap_ip_address}")
          if bootstrap_ip_address.nil?
            error_message = "No IP address available for bootstrapping."
            ui.error(error_message)
            raise CloudExceptions::BootstrapError, error_message
          end
          config[:bootstrap_ip_address] = bootstrap_ip_address
        end

        def validate_params!
          # set param vm_name to a random value if the name is not set by the user (plugin)
          config[:chef_node_name] = get_node_name(locate_config_value(:chef_node_name), locate_config_value(:chef_node_name_prefix))

          errors = []
          
          if locate_config_value(:bootstrap_protocol) == 'winrm'
            if locate_config_value(:winrm_password).nil?
              errors << "You must provide Winrm Password."
            end
          elsif locate_config_value(:bootstrap_protocol) != 'ssh'
            errors << "You must provide a valid bootstrap protocol. options [ssh/winrm]. For linux type images, options [ssh]"
          end

          errors << "You must provide --image-os-type option [windows/linux]" if ! (%w(windows linux).include?(locate_config_value(:image_os_type)))
          error_message = ""
          raise CloudExceptions::ValidationError, error_message if errors.each{|e| ui.error(e); error_message = "#{error_message} #{e}."}.any?
        end
      end
    end
  end
end
