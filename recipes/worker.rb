#
# Cookbook Name:: site-reviewtypo3org
# Recipe:: worker
#
# Copyright 2013, TYPO3 Association
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
require 'mixlib/shellout'
require 'shellwords'

deploy_base = "/srv/mq-worker-reviewtypo3org"

package "ruby"
package "bundler"

gerrit_ssh_port = '29418'
app_owner = 'mqwreview'
app_group = 'mqwreview'

admin_user = node['gerrit']['batch_admin_user']['username']
admin_key_file = node['gerrit']['home'] + "/.ssh/id_rsa-#{admin_user}"
gerrit_host = node['gerrit']['hostname']

mq_gerrit_user = node['site-reviewtypo3org']['mq-worker']['gerrit']['user']
mq_gerrit_user_fullname = node['site-reviewtypo3org']['mq-worker']['gerrit']['user_fullname']
mq_gerrit_user_email = node['site-reviewtypo3org']['mq-worker']['gerrit']['user_email']


# create group and user
group "#{app_group}" do
  system true
end

user "#{app_owner}" do
  gid "#{app_group}"
  home "#{deploy_base}"
  comment "MQ Worker for review"
  shell "/bin/bash"
  system true
end

# create shared config directory
[deploy_base, "#{deploy_base}/shared", "#{deploy_base}/shared/config"].each do |dir|
  directory dir do
    owner app_owner
    group app_group
    recursive true
    action :create
  end
end

# handle amqp password
if Chef::Config[:solo]
  Chef::Log.warn "AMQP connection will be disabled as running inside of chef-solo!"
  amqp_pass = "fooo"
else
  Chef::Log.info "AMQP credentials: #{node['site-reviewtypo3org']['amqp']['user']}@#{node['site-reviewtypo3org']['amqp']['server']}"

  # read AMQP password from chef-vault
  include_recipe "t3-chef-vault"
  amqp_pass = chef_vault_password(node['site-reviewtypo3org']['amqp']['server'], node['site-reviewtypo3org']['amqp']['user'])

end


# create a proper amqp.yml
template "#{deploy_base}/shared/config/amqp.yml" do
  owner      app_owner
  group      app_group
  source     "worker/amqp.yml.erb"
  variables({
    :data => {
      :user => node['site-reviewtypo3org']['amqp']['user'],
      :pass => amqp_pass,
      :host => node['site-reviewtypo3org']['amqp']['server'],
      :vhost => node['site-reviewtypo3org']['amqp']['vhost']
    }
  })
end

# create ssh key for mq-worker to connect to gerrit
ssh_key_filename = "id_rsa-#{node['site-reviewtypo3org']['mq-worker']['gerrit']['user']}"
ssh_key = deploy_base + "/.ssh/" + ssh_key_filename
execute "generate private ssh key for 'Gerrit Code Review' user" do
  command "ssh-keygen -t rsa -q -f #{ssh_key} -C\"#{mq_gerrit_user_email}\""
  user app_owner
  creates ssh_key
  #not_if { File.exists?ssh_key }
end

# add ssh_known_hosts for gerrit ssh
ssh_known_hosts "#{gerrit_host}:#{gerrit_ssh_port}" do
  user app_owner
end

# ssh_config
ssh_config "#{gerrit_host}" do
  options ({
    'User' => "#{mq_gerrit_user}",
    'IdentityFile' => "~/.ssh/#{ssh_key_filename}",
    'Port' => "#{gerrit_ssh_port}"
  })
  user app_owner
end

Chef::Recipe.send(:include, Gerrit::Helpers)
ruby_block "site-review mq-worker create gerrit mq user" do
  block do
    has_mq_user = ssh_can_connect?(mq_gerrit_user, ssh_key, gerrit_host, gerrit_ssh_port)
    unless has_mq_user then
      has_admin_user = ssh_can_connect?(admin_user, admin_key_file, gerrit_host, gerrit_ssh_port)
      if has_admin_user
        public_key_content = Shellwords.shellescape(File.read("#{ssh_key}.pub"))
        fullname = Shellwords.shellescape(mq_gerrit_user_fullname)
        gerrit_create_cmd = "gerrit create-account --group \"Non-Interactive\\ Users\" --group \"Administrators\" --full-name \"#{fullname}\" --email \"#{mq_gerrit_user_email}\" --ssh-key \"#{public_key_content}\" #{mq_gerrit_user}"
        create_mq_user_shell =  Mixlib::ShellOut.new("ssh -o StrictHostKeyChecking=no -i #{admin_key_file} -p #{gerrit_ssh_port} -l #{admin_user} #{gerrit_host} #{gerrit_create_cmd}")
        create_mq_user_shell.run_command
        if create_mq_user_shell.error?
          msg = "execution error"
          create_mq_user_shell.invalid!(msg)
          #raises exeception
        end
      else
        msg = "mq-worker cant connect to gerrit and also cant be created, pls fix manually: #{admin_user} #{admin_key_file} #{gerrit_host}"
        raise "#{msg}"
      end
    end
  end
end

# create a proper gerrit.yml for the worker
template "#{deploy_base}/shared/config/gerrit.yml" do
  owner      app_owner
  group      app_group
  source     "worker/gerrit.yml.erb"
  variables({
    :data => {
      :user => mq_gerrit_user,
      :git_user_email => mq_gerrit_user_email,
      :git_user_name => mq_gerrit_user_fullname,
      :host => node['gerrit']['hostname'],
      :port => gerrit_ssh_port,
    }
  })
end


# deploy resource for mq-worker-gerrittypo3org
deploy_revision "mq-worker-reviewtypo3org" do
  #action  :force_deploy
  deploy_to      deploy_base
  repository     "https://github.com/TYPO3-infrastructure/mq-worker-reviewtypo3org"
  migrate        false
  user           app_owner
  group          app_group
  symlink_before_migrate ({
    'config/amqp.yml' => 'config/amqp.yml',
    'config/gerrit.yml' => 'config/gerrit.yml'
  })
  before_symlink do

    directory "#{deploy_base}/shared/log" do
      owner app_owner
      group app_group
    end

    execute "bundle install --path=vendor/bundle --without development test" do
      cwd release_path
      user app_owner
    end

  end
  notifies :restart, "runit_service[mq-worker-reviewtypo3org]"
end


include_recipe "runit"

runit_service "mq-worker-reviewtypo3org" do
  owner          app_owner
  group          app_group
  default_logger true
  options ({
    :deploy_base => deploy_base,
    :app_owner => app_owner,
    :app_group => app_group}.merge(params)
  )
end
