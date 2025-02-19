require 'beaker-rspec/spec_helper'
require 'beaker-rspec/helpers/serverspec'
require 'beaker/puppet_install_helper'

begin
  require 'pry'
rescue LoadError # rubocop:disable Lint/HandleExceptions for optional loading
end

run_puppet_install_helper unless ENV['BEAKER_provision'] == 'no'

RSpec.configure do |c|
  # Project root
  proj_root = File.expand_path(File.join(File.dirname(__FILE__), '..'))

  # Readable test descriptions
  c.formatter = :documentation

  # Configure all nodes in nodeset
  c.before :suite do
    # Install module and dependencies
    hosts.each do |host|
      # Return the hostname on :dashboard
      vmhostname = on(host, 'hostname', acceptable_exit_codes: [0]).stdout.strip
      vmipaddr = on(host, "ip route get 8.8.8.8 | awk '{print $NF; exit}'", acceptable_exit_codes: [0]).stdout.strip
      os = fact_on(host, 'osfamily')

      copy_module_to(host, :source => proj_root, :module_name => 'helm')
      if fact_on(host, 'operatingsystem') == 'RedHat'
        on(host, 'mv /etc/yum.repos.d/redhat.repo /etc/yum.repos.d/internal-mirror.repo')
      end

      on(host, 'yum update -y -q') if fact_on(host, 'osfamily') == 'RedHat'
      
      on host, puppet('module', 'install', 'puppetlabs-kubernetes'), { :acceptable_exit_codes => [0,1] }
      on host, puppet('module', 'install', 'puppetlabs-stdlib'), { :acceptable_exit_codes => [0,1] }
      on host, puppet('module', 'install', 'puppet-archive'), { :acceptable_exit_codes => [0,1] }
      on host, puppet('module', 'install', 'puppetlabs-docker'), { :acceptable_exit_codes => [0,1] }

      # shell('echo "#{vmhostname}" > /etc/hostname')
      # shell("hostname #{vmhostname}")
      hosts_file = <<-EOS
127.0.0.1 localhost #{vmhostname} kubernetes kube-master
#{vmipaddr} #{vmhostname}
#{vmipaddr} kubernetes
#{vmipaddr} kube-master
      EOS

      nginx = <<-EOS
apiVersion: v1
kind: Namespace
metadata:
  name: nginx
---
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  name: my-nginx
  namespace: nginx
spec:
  template:
    metadata:
      labels:
        run: my-nginx
    spec:
      containers:
      - name: my-nginx
        image: nginx:1.12-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: my-nginx
  namespace: nginx
  labels:
    run: my-nginx
spec:
  clusterIP: 10.96.188.5
  ports:
  - port: 80
    protocol: TCP
  selector:
    run: my-nginx
EOS

hiera = <<-EOS
version: 5
defaults:
  datadir: /etc/puppetlabs/code/environments/production/hieradata
  data_hash: yaml_data
hierarchy:
  - name: "Per-node data (yaml version)"
    path: "nodes/%{trusted.certname}.yaml" # Add file extension.
    # Omitting datadir and data_hash to use defaults.

  - name: "Other YAML hierarchy levels"
    paths: # Can specify an array of paths instead of one.
      - "location/%{facts.whereami}/%{facts.group}.yaml"
      - "groups/%{facts.group}.yaml"
      - "os/%{facts.os.family}.yaml"
      - "%{facts.os.family}.yaml"
      - "#{vmhostname}.yaml"
      - "Redhat.yaml"
      - "common.yaml"
EOS
        if fact('osfamily') == 'Debian'
          runtime = 'cri_containerd'
          cni = 'weave'
          #Installing rubydev environment
          on(host, "apt install ruby-bundler --yes", acceptable_exit_codes: [0]).stdout
          on(host, "apt-get install ruby-dev --yes", acceptable_exit_codes: [0]).stdout
          on(host, "apt-get install build-essential curl git m4 python-setuptools ruby texinfo libbz2-dev libcurl4-openssl-dev libexpat-dev libncurses-dev zlib1g-dev --yes", acceptable_exit_codes: [0]).stdout
          on(host, "gem install bundler", acceptable_exit_codes: [0]).stdout
        end
        if fact('osfamily') == 'RedHat'
          runtime = 'docker'
          cni = 'flannel'
          #Installing rubydev environment
          on(host, "yum install -y ruby-devel git zlib-devel gcc-c++ lib yaml-devel libffi-devel make bzip2 libtool curl openssl-devel readline-devel", acceptable_exit_codes: [0]).stdout
          on(host, "gem install bundler", acceptable_exit_codes: [0]).stdout
          #Installing docker
          on(host, "setenforce 0 || true", acceptable_exit_codes: [0]).stdout
          on(host, "swapoff -a", acceptable_exit_codes: [0]).stdout
          on(host, "systemctl stop firewalld && systemctl disable firewalld", acceptable_exit_codes: [0]).stdout
          on(host, "yum install -y yum-utils device-mapper-persistent-data lvm2", acceptable_exit_codes: [0]).stdout 
          on(host, "yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo", acceptable_exit_codes: [0]).stdout 
          on(host, "yum install -y docker-ce-18.06.3.ce-3.el7", acceptable_exit_codes: [0]).stdout 
          on(host, "usermod -aG docker $(whoami)", acceptable_exit_codes: [0]).stdout 
          on(host, "systemctl enable docker.service", acceptable_exit_codes: [0]).stdout 
          on(host, "sudo systemctl start docker.service", acceptable_exit_codes: [0]).stdout
          if fact('operatingsystem') != 'RedHat'
            on(host, "yum install -y epel-release", acceptable_exit_codes: [0]).stdout
          end
          if fact_on(host, 'operatingsystem') == 'RedHat'
            on(host, 'mv /etc/yum.repos.d/redhat.repo /etc/yum.repos.d/internal-mirror.repo')
            on(host, 'rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm')
          end
          on(host, 'yum update -y -q') if fact_on(host, 'osfamily') == 'RedHat'
          on(host, "yum install -y python-pip", acceptable_exit_codes: [0]).stdout
          on(host, "pip install docker-compose", acceptable_exit_codes: [0]).stdout 
          on(host, "yum upgrade python*", acceptable_exit_codes: [0]).stdout
        end

        # Installing go, cfssl
        on(host, "cd  /etc/puppetlabs/code/environments/production/modules/kubernetes;rm -rf Gemfile.lock;bundle install --path vendor/bundle", acceptable_exit_codes: [0]).stdout
        on(host, "curl -o go.tar.gz https://storage.googleapis.com/golang/go1.12.9.linux-amd64.tar.gz", acceptable_exit_codes: [0]).stdout
        on(host, "tar -C /usr/local -xzf go.tar.gz", acceptable_exit_codes: [0]).stdout
        on(host, "export PATH=$PATH:/usr/local/go/bin;go get -u github.com/cloudflare/cfssl/cmd/...", acceptable_exit_codes: [0]).stdout
        # Creating certs
        on(host, "export PATH=$PATH:/usr/local/go/bin;export PATH=$PATH:/root/go/bin;cd  /etc/puppetlabs/code/environments/production/modules/kubernetes/tooling;./kube_tool.rb -o #{os} -v 1.13.5 -r #{runtime} -c #{cni} -i \"#{vmhostname}:#{vmipaddr}\" -t \"#{vmipaddr}\" -a \"#{vmipaddr}\" -d true", acceptable_exit_codes: [0]).stdout
        create_remote_file(host, "/etc/hosts", hosts_file)
        create_remote_file(host, "/tmp/nginx.yml", nginx)
        create_remote_file(host,"/etc/puppetlabs/puppet/hiera.yaml", hiera)
        create_remote_file(host,"/etc/puppetlabs/code/environments/production/hiera.yaml", hiera)
        on(host, 'mkdir -p /etc/puppetlabs/code/environments/production/hieradata', acceptable_exit_codes: [0]).stdout
        on(host, 'cp /etc/puppetlabs/code/environments/production/modules/kubernetes/tooling/*.yaml /etc/puppetlabs/code/environments/production/hieradata/', acceptable_exit_codes: [0]).stdout

        if fact('osfamily') == 'Debian'
          on(host, 'sed -i /cni_network_provider/d /etc/puppetlabs/code/environments/production/hieradata/Debian.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'echo "kubernetes::cni_network_provider: https://cloud.weave.works/k8s/net?k8s-version=1.13.5" >> /etc/puppetlabs/code/environments/production/hieradata/Debian.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'echo "kubernetes::schedule_on_controller: true"  >> /etc/puppetlabs/code/environments/production/hieradata/Debian.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'echo "kubernetes::taint_master: false" >> /etc/puppetlabs/code/environments/production/hieradata/Debian.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'export KUBECONFIG=\'/etc/kubernetes/admin.conf\'', acceptable_exit_codes: [0]).stdout       
        end

        if fact('osfamily') == 'RedHat'
          on(host, 'sed -i /cni_network_provider/d /etc/puppetlabs/code/environments/production/hieradata/Redhat.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'echo "kubernetes::cni_network_provider: https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" >> /etc/puppetlabs/code/environments/production/hieradata/Redhat.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'echo "kubernetes::schedule_on_controller: true"  >> /etc/puppetlabs/code/environments/production/hieradata/Redhat.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'echo "kubernetes::taint_master: false" >> /etc/puppetlabs/code/environments/production/hieradata/Redhat.yaml', acceptable_exit_codes: [0]).stdout
          on(host, 'export KUBECONFIG=\'/etc/kubernetes/admin.conf\'', acceptable_exit_codes: [0]).stdout       
        end

        # Disable swap
        on(host, 'swapoff -a')
    end
  end
end
