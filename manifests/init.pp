class cephdeploy(
  $has_compute          = true,
  $user                 = hiera('ceph_deploy_user'),
  $pass                 = hiera('ceph_deploy_password'),
  $fsid                 = hiera('ceph_monitor_fsid'),
  $mon_initial_members  = hiera('mon_initial_members'),
  $ceph_monitor_address = hiera('ceph_monitor_address'),
  $ceph_public_network  = hiera('ceph_public_network'),
  $ceph_cluster_network = hiera('ceph_cluster_network'),

){

## User setup

  user {$user:
    ensure   => present,
    password => $pass,
    home     => "/home/$user",
    shell    => '/bin/bash',
  }

  file {"/home/$user":
    ensure  => directory,
    owner   => $user,
    group   => $user,
    mode    => 0755,
    require => User[$user],
  }
  
  file {"/home/$user/.ssh":
    ensure  => directory,
    owner   => $user,
    group   => $user,
    mode    => 0700,
    require => File["/home/$user"],
  }

  file {"/home/$user/.ssh/id_rsa":
    content => template('cephdeploy/id_rsa.erb'),
    owner   => $user,
    group   => $user,
    mode    => 0600,
    require => File["/home/$user/.ssh"],
  }

  file {"/home/$user/.ssh/id_rsa.pub":
    content => template('cephdeploy/id_rsa.pub.erb'),
    owner   => $user,
    group   => $user,
    mode    => 0644,
    require => File["/home/$user/.ssh"],
  }

  file {"/home/$user/.ssh/authorized_keys":
    content => template('cephdeploy/id_rsa.pub.erb'),
    owner   => $user,
    group   => $user,
    mode    => 0600,
    require => File["/home/$user/.ssh"],
  }

  file {"/home/$user/.ssh/config":
    content => template('cephdeploy/config.erb'),
    owner   => $user,
    group   => $user,
    mode    => 0600,
    require => File["/home/$user/.ssh"],
  }

  file {"log $user":
    owner   => $user,
    group   => $user,
    mode    => 0777,
    path    => "/home/$user/bootstrap/ceph.log",
    require => [ Exec["install ceph"], File["/etc/sudoers.d/$user"], File["/home/$user"], User[$user] ],
  }

  exec {'passwordless sudo for ceph deploy user':
    command => "/bin/echo \"$user ALL = NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/$user",
    unless  => "/usr/bin/test -e /etc/sudoers.d/$user",
  }

  file {"/etc/sudoers.d/$user":
    mode    => 0440,
    require => Exec['passwordless sudo for ceph deploy user'],
  }

  file { "/home/$user/zapped":
    owner   => $user,
    group   => $user,
    ensure  => directory,
    require => File["/home/$user"]
  }

  file {"/home/$user/bootstrap":
    ensure  => directory,
    owner   => $user,
    group   => $user,
    require => File["/home/$user"]
  }

## Install ceph and dependencies

  if ! defined(Package['python-pip']) {
    package {'python-pip':
      ensure => installed,
    }
  }

  exec {'install ceph-deploy':
    command => '/usr/bin/pip install ceph-deploy', 
    unless  => '/usr/bin/pip install ceph-deploy | /bin/grep satisfied',
    require => [ Package['python-pip'], File["/home/$user"] ],
  }

## ceph.conf setup

  concat { "/home/$user/bootstrap/ceph.conf":
    owner   => $user,
    group   => $user,
    path    => "/home/$user/bootstrap/ceph.conf",
    require => File["/home/$user/bootstrap"],
  }

  concat::fragment { 'ceph':
    target  => "/home/$user/bootstrap/ceph.conf",
    order   => '01',
    content => template('cephdeploy/ceph.conf.erb'),
    require => File["/home/$user/bootstrap"],
  }

## Keyring setup

  file { "ceph.mon.keyring":
    owner   => $user,
    group   => $user,
    path    => "/home/$user/bootstrap/ceph.mon.keyring",
    content => template('cephdeploy/ceph.mon.keyring.erb'),
    require => File["/home/$user/bootstrap/ceph.conf"],
  }

  exec { "install ceph":
    cwd      => "/home/$user/bootstrap",
    command  => "/usr/bin/sudo /usr/local/bin/ceph-deploy install --stable emperor $::hostname",
    unless   => '/usr/bin/which ceph',
    require  => [ Exec['install ceph-deploy'], File['ceph.mon.keyring'], File["/home/$user/bootstrap"] ],
    user     => $user,
  }

  file {'service perms':
    mode    => 0644,
    path    => '/etc/ceph/ceph.client.admin.keyring',
    require => Exec['install ceph'],
  }

  file {'conf perms':
    mode    => 0644,
    path    => '/etc/ceph/ceph.conf',
    require => Exec['install ceph'],
  }


## If the ceph node is also running nova-compute

  if $has_compute {

    file { '/etc/ceph/secret.xml':
      content => template('cephdeploy/secret.xml-compute.erb'),
      require => Exec['install ceph'],
    }

    exec { 'get-or-set virsh secret':
      command => '/usr/bin/virsh secret-define --file /etc/ceph/secret.xml | /usr/bin/awk \'{print $2}\' | sed \'/^$/d\' > /etc/ceph/virsh.secret',
      creates => "/etc/ceph/virsh.secret",
      require => [ Package['libvirt-bin'], File['/etc/ceph/secret.xml'] ],
    }

    exec { 'set-secret-value virsh':
      command => "/usr/bin/virsh secret-set-value --secret $(cat /etc/ceph/virsh.secret) --base64 $(ceph auth get-key client.admin)",
      require => Exec['get-or-set virsh secret'],
    }

  }


}
