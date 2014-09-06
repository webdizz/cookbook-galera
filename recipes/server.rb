#
# Cookbook Name:: galera
# Recipe:: galera_server
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

package 'libaio'

install_flag = "/root/.s9s_galera_installed"

group "mysql" do
end

user "mysql" do
  gid "mysql"
  comment "MySQL server"
  system true
  shell "/bin/false"
end

galera_config = data_bag_item('s9s_galera', 'config')
mysql_tarball = galera_config['mysql_wsrep_tarball_' + node['kernel']['machine']]
# strip .tar.gz
mysql_package = mysql_tarball[0..-8]

mysql_wsrep_source = galera_config['mysql_wsrep_source']
galera_source = galera_config['galera_source']

Chef::Log.info "Downloading #{mysql_tarball}"
remote_file "#{Chef::Config[:file_cache_path]}/#{mysql_tarball}" do
  source "#{mysql_wsrep_source}/" + mysql_tarball
  action :create_if_missing
end

case node['platform']
when 'centos', 'redhat', 'fedora', 'suse', 'scientific', 'amazon'
  galera_package = galera_config['galera_package_' + node['kernel']['machine']]['rpm']
else
  galera_package = galera_config['galera_package_' + node['kernel']['machine']]['deb']
end

Chef::Log.info "Downloading #{galera_package}"
remote_file "#{Chef::Config[:file_cache_path]}/#{galera_package}" do
  source "#{galera_source}/" + galera_package
  action :create_if_missing
end

bash "install-mysql-package" do
  user "root"
  code <<-EOH
    zcat #{Chef::Config[:file_cache_path]}/#{mysql_tarball} | tar xf - -C #{node['mysql']['install_dir']}
    ln -sf #{node['mysql']['install_dir']}/#{mysql_package} #{node['mysql']['base_dir']}
  EOH
  not_if { File.directory?("#{node['mysql']['install_dir']}/#{mysql_package}") }
end

case node['platform']
  when 'centos', 'redhat', 'fedora', 'suse', 'scientific', 'amazon'
    bash "purge-mysql-galera" do
      user "root"
      code <<-EOH
        killall -9 mysqld_safe mysqld &> /dev/null
        yum remove mysql mysql-libs mysql-devel mysql-server mysql-bench
        cd #{node['mysql']['data_dir']}
        [ $? -eq 0 ] && rm -rf #{node['mysql']['data_dir']}/*
        rm -rf /etc/my.cnf /etc/mysql
        rm -f /root/#{install_flag}
      EOH
      only_if { !FileTest.exists?("#{install_flag}") }
    end
  else
    bash "purge-mysql-galera" do
      user "root"
      code <<-EOH
        killall -9 mysqld_safe mysqld &> /dev/null
        apt-get -y remove --purge mysql-server mysql-client mysql-common
        apt-get -y autoremove
        apt-get -y autoclean
        cd #{node['mysql']['data_dir']}
        [ $? -eq 0 ] && rm -rf #{node['mysql']['data_dir']}/*
        rm -rf /etc/my.cnf /etc/mysql
        rm -f /root/#{install_flag}
      EOH
      only_if { !FileTest.exists?("#{install_flag}") }
    end
end

case node['platform']
when 'centos', 'redhat', 'fedora', 'suse', 'scientific', 'amazon'
  bash "install-galera" do
    user "root"
    code <<-EOH
      yum -y localinstall #{node['xtra']['packages']}
      yum -y localinstall #{Chef::Config[:file_cache_path]}/#{galera_package}
    EOH
    not_if { FileTest.exists?("#{node['wsrep']['provider']}") }
  end
else
  bash "install-galera" do
    user "root"
    code <<-EOH
      apt-get -y --force-yes install #{node['xtra']['packages']}
      dpkg -i #{Chef::Config[:file_cache_path]}/#{galera_package}
      apt-get -f install
    EOH
    not_if { FileTest.exists?("#{node['wsrep']['provider']}") }
  end
end

directory node['mysql']['data_dir'] do
  owner "mysql"
  group "mysql"
  mode "0755"
  action :create
  recursive true
end

directory node['mysql']['run_dir'] do
  owner "mysql"
  group "mysql"
  mode "0755"
  action :create
  recursive true
end
