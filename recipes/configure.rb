#
# Cookbook Name:: galera
# Recipe:: configure
#
# Copyright 2012, Severalnines AB.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

install_flag = "/root/.s9s_galera_installed"
galera_config = data_bag_item('s9s_galera', 'config')

# install db to the data directory
execute "setup-mysql-datadir" do
  command "#{node['mysql']['base_dir']}/scripts/mysql_install_db --force --user=mysql --basedir=#{node['mysql']['base_dir']} --datadir=#{node['mysql']['data_dir']}"
  not_if { FileTest.exists?("#{node['mysql']['data_dir']}/mysql/user.frm") }
end


execute "setup-init.d-mysql-service" do
  command "cp #{node['mysql']['base_dir']}/support-files/mysql.server /etc/init.d/#{node['mysql']['servicename']}"
  not_if { FileTest.exists?("#{install_flag}") }
end

template "my.cnf" do
  path "#{node['mysql']['conf_dir']}/my.cnf"
  source "my.cnf.erb"
  owner "mysql"
  group "mysql"
  mode "0644"
#  notifies :restart, "service[mysql]", :delayed
end

my_ip = node["network"]["interfaces"][node['galera']['bind_interface']]["addresses"].keys[1]

init_host = node['galera']['init_node']

sync_host = init_host

hosts = node['galera']['nodes'].reject! { |c| c.empty? } unless node['galera']['nodes'].empty?

Chef::Log.warn "init_host = #{init_host}, my_ip = #{my_ip}, hosts = #{hosts}"
if File.exists?("#{install_flag}") && hosts != nil && hosts.length > 0
  i = 0
  begin
    sync_host = hosts[rand(hosts.count)]
    i += 1
    if (i > hosts.count)
      # no host found, use init node/host
      sync_host = init_host
      break
    end
  end while my_ip == sync_host
end

wsrep_cluster_address = 'gcomm://'
if !File.exists?("#{install_flag}") && hosts != nil && hosts.length > 0
  hosts.each do |h|
    wsrep_cluster_address += "#{h}:#{node['wsrep']['port']},"
  end
  wsrep_cluster_address = wsrep_cluster_address[0..-2]
end

Chef::Log.info "wsrep_cluster_address = #{wsrep_cluster_address}"
bash "set-wsrep-cluster-address" do
  user "root"
  code <<-EOH
  sed -i 's#.*wsrep_cluster_address.*=.*#wsrep_cluster_address=#{wsrep_cluster_address}#' #{node['mysql']['conf_dir']}/my.cnf
  EOH
  only_if { (galera_config['update_wsrep_urls'] == 'yes') || !FileTest.exists?("#{install_flag}") }
end

service "init-cluster" do
  service_name node['mysql']['servicename']
  supports :start => true
  start_command "service #{node['mysql']['servicename']} start --wsrep-cluster-address=gcomm://"
  action [:enable, :start]
  only_if { my_ip == init_host && !FileTest.exists?("#{install_flag}") }
end

if my_ip != init_host && !File.exists?("#{install_flag}")
  Chef::Log.info "Joiner node sleeping 30 seconds to make sure donor node is up..."
  sleep(node['xtra']['sleep'])
  Chef::Log.info "Joiner node cluster address = gcomm://#{sync_host}:#{node['wsrep']['port']}"
end

service "join-cluster" do
  service_name node['mysql']['servicename']
  supports :restart => true, :start => true, :stop => true
  action [:enable, :start]
  only_if { my_ip != init_host && !FileTest.exists?("#{install_flag}") }
end

bash "wait-until-synced" do
  user "root"
  code <<-EOH
    state=0
    cnt=0
    until [[ "$state" == "4" || "$cnt" > 5 ]]
    do
      state=$(#{node['mysql']['mysql_bin']} -uroot -hlocalhost -e "SET wsrep_on=0; SHOW GLOBAL STATUS LIKE 'wsrep_local_state'")
      state=$(echo "$state"  | tr '\n' ' ' | awk '{print $4}')
      cnt=$(($cnt + 1))
      sleep 1
    done
  EOH
  only_if { my_ip == init_host && !FileTest.exists?("#{install_flag}") }
end

bash "set-wsrep-grants-mysqldump" do
  user "root"
  code <<-EOH
#{node['mysql']['mysql_bin']} -uroot -hlocalhost -e "GRANT ALL ON *.* TO '#{node['wsrep']['user']}'@'%' IDENTIFIED BY '#{node['wsrep']['password']}'"
    #{node['mysql']['mysql_bin']} -uroot -hlocalhost -e "SET wsrep_on=0; GRANT ALL ON *.* TO '#{node['wsrep']['user']}'@'localhost' IDENTIFIED BY '#{node['wsrep']['password']}'"
  EOH
  only_if { my_ip == init_host && (galera_config['sst_method'] == 'mysqldump') && !FileTest.exists?("#{install_flag}") }
end

bash "secure-mysql" do
  user "root"
  code <<-EOH
#{node['mysql']['mysql_bin']} -uroot -hlocalhost -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE DB='test' OR DB='test\\_%'"
    #{node['mysql']['mysql_bin']} -uroot -hlocalhost -e "UPDATE mysql.user SET Password=PASSWORD('#{node['mysql']['root_password']}') WHERE User='root'; DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'); FLUSH PRIVILEGES;"
  EOH
  only_if { my_ip == init_host && (galera_config['secure'] == 'yes') && !FileTest.exists?("#{install_flag}") }
end

service "mysql" do
  supports :restart => true, :start => true, :stop => true
  service_name node['mysql']['servicename']
  action :nothing
  only_if { FileTest.exists?("#{install_flag}") }
end
