# installs and configures all dependencies of Nextcloud
class profile_nextcloud (
  $servername,
  $manage_repos             = true,
  $local_mysql              = true,
  $database_name            = 'nextcloud',
  $database_user            = 'nextcloud',
  $database_pass            = undef,
  $admin_username           = undef,
  $admin_pass               = undef,
  $data_dir                 = '/srv/nextcloud-data',
  $create_data_dir          = true,
  $database_root_pass       = undef,
  # wether to redirect non ssl traffic to ssl, or support access using non-ssl access
  $redirect_ssl             = true,
  $external_db_host         = undef,
  $ldap_password            = undef,
  $ldap_base                = undef,
  $ldap_dn                  = undef,
  $ldap_group_filter        = undef,
  $ldap_host                = undef,
  $ldap_login_filter        = undef,
  $ldap_userlist_filter     = undef,
  $proxy_trusted_proxies    = undef,
  $proxy_overwritehost      = undef,
  $proxy_overwriteprotocol  = undef,
  $install_method           = 'filesystem',
  $php_max_execution_time   = 3600,
  $php_max_input_time       = 3600,
  $php_memory_limit         = '128M',
  $php_post_max_size        = '16G',
  $php_upload_max_filseize  = '16G',
  $php_timezone) {

  if ($manage_repos) {
    class { '::profile_nextcloud::repos':
      before => Class['Nextcloud'],
    }
    class { '::php::repo::redhat':
      before   => Class['Nextcloud'],
      yum_repo => 'remi_php71',
    }
  }

  class { 'apache':
    manage_user => false
  }

  include ::collectd

  file { ['/etc/httpd', '/etc/httpd/certs']:
    ensure  => directory,
  }->
  profile_openssl::self_signed_certificate { 'nextcloud':
    key_owner         => 'root',
    key_group         => 'root',
    key_mode          => '0600',
    cert_country      => 'BE',
    cert_state        => 'BE',
    cert_common_names => [$servername],
    key_path          => '/etc/httpd/certs/nextcloud.key',
    cert_path         => '/etc/httpd/certs/nextcloud.cert',
    notify            => Service['httpd'],
  }->
  apache::vhost {"${servername}-ssl":
    servername    => $servername,
    port          => '443',
    docroot       => '/var/www/html/nextcloud',
    directories   => [
      { 'path'           => '/var/www/html/nextcloud',
        'deny'           => 'from all',
        'allow_override' => ['All'],
        'options'        => ['FollowSymLinks'],
        'setenv'         => ['HOME /var/www/html/nextcloud', 'HTTP_HOME /var/www/html/nextcloud'],
        'Dav'            => 'Off',
      },
    ],
    docroot_owner => 'apache',
    docroot_group => 'apache',
    ssl           => true,
    ssl_cert      => '/etc/httpd/certs/nextcloud.cert',
    ssl_key       => '/etc/httpd/certs/nextcloud.key',
  }

  if ($redirect_ssl) {
    apache::vhost {"${servername}-redirect":
      servername      => $servername,
      port            => '80',
      docroot         => '/var/www/html/nextcloud',
      redirect_status => 'permanent',
      redirect_dest   => "https://${servername}"
    }
  } else {
    apache::vhost {"${servername}-no-ssl":
      servername    => $servername,
      port          => '80',
      docroot       => '/var/www/html/nextcloud',
      directories   => [
        { 'path'           => '/var/www/html/nextcloud',
          'deny'           => 'from all',
          'allow_override' => ['All'],
          'options'        => ['FollowSymLinks'],
          'setenv'         => ['HOME /var/www/html/nextcloud', 'HTTP_HOME /var/www/html/nextcloud'],
          'Dav'            => 'Off',
        },
      ],
      docroot_owner => 'apache',
      docroot_group => 'apache',
    }
  }

  class { 'apache::mod::headers': }

  if ($local_mysql) {
    class { '::mysql::server':
      root_password           => $database_root_pass,
      remove_default_accounts => true
    }

    mysql::db { $database_name:
      user     => $database_user,
      password => $database_pass,
      host     => 'localhost',
      grant    => ['ALL'],
    }
    $database_host = 'localhost'
    Mysql::Db[$database_name]->Exec['install-nextcloud']
  } else {
    @@::mysql::db { "${::environment}_nextcloud_${::fqdn}":
      user     => $database_user,
      password => $database_pass,
      dbname   => $database_name,
      host     => $::fqdn,
      grant    => ['ALL'],
      tag      => "${::datacenter}_${::environment}",
    }
    $database_host = $external_db_host
  }

  class { '::profile_redis::standalone':
    save_db_to_disk    => false,
    status_page_path   => false,
    php_redis_pkg_name => false,
    unixsocket_path    => '/var/run/redis/redis.sock',
    unixsocket_perm    => 770
  }->
  user { 'apache':
    ensure  => present,
    groups  => [redis],
    require => Class['::apache'],
    notify  => Service['httpd']
  }
  class { '::php::globals':
    php_version => '7.1',
    config_root => '/etc/php/7.1',
  }->
  class { '::php':
    manage_repos => false,
    fpm          => false,
    composer     => false,
    extensions   => {
      'gd'           => {},
      'mbstring'     => {},
      'pecl-imagick' => {
        'ensure'   => 'installed',
        'so_name'  => 'imagick',
        'settings' => {
          'imagick.skip_version_check' => 1
        }
      },
      'pecl-zip'     => {
        'ensure'  => 'installed',
        'so_name' => 'zip'
      },
      'pecl-redis'   => {
        'ensure'  => 'installed',
        'so_name' => 'redis'
      },
      'opcache'      => {
        'ensure'   => 'installed',
        'settings' => {
          # recommended options by Nextcloud https://docs.nextcloud.com/server/12/admin_manual/configuration_server/server_tuning.html?highlight=opcache#enable-php-opcache
          'opcache.enable'                  => 1,
          'opcache.enable_cli'              => 1,
          'opcache.interned_strings_buffer' => 8,
          'opcache.max_accelerated_files'   => 10000,
          'opcache.memory_consumption'      => 128,
          'opcache.save_comments'           => 1,
          'opcache.revalidate_freq'         => 1
        },
        'zend'     => true
      },
    },
    settings     => {
      'PHP/max_execution_time'  => $php_max_execution_time,
      'PHP/max_input_time'      => $php_max_input_time,
      'PHP/memory_limit'        => $php_memory_limit,
      'PHP/post_max_size'       => $php_post_max_size,
      'PHP/upload_max_filesize' => $php_upload_max_filseize,
      'Date/date.timezone'      => $php_timezone,
    },
  } ->
  class { 'apache::mod::php':
    package_name => 'php', # mod_php from remi
    php_version  => '7'  # the modulen is called phplib7 not phplib71
  }->
  # remove the default configuration files, since puppet provides files for the modules
  file { '/etc/php.d/40-imagick.ini':
    ensure => absent,
  }->
  file { '/etc/php.d/40-zip.ini':
    ensure => absent,
  }->
  file { '/etc/php.d/50-redis.ini':
    ensure => absent,
  }->
  file { '/etc/php.d/10-opcache.ini':
    ensure => absent,
  }->
  file { '/etc/php.d/20-pdo.ini':
    ensure  => present,
    content => 'extension=pdo.so',
    notify  => Service['httpd']
  }->
  file { '/etc/php.d/pdo.ini':
    ensure => absent,
  }->
  file { '/etc/php.d/20-gd.ini':
    ensure => absent,
  }->
  file { '/etc/php.d/20-mbstring.ini':
    ensure => absent,
  }->
  # we don't use the puppet php module to install php-mysqlnd and php-ldap
  # because the puppte module creates it's own config file (and doesn't remove
  # the one from the OS), but doesn't add the priority to the filename
  # see https://github.com/voxpupuli/puppet-php/issues/272
  package { 'php-mysqlnd':
    ensure => present,
  }->
  package { 'php-ldap':
    ensure => present,
  }->
  class { 'nextcloud':
    servername      => $servername,
    local_mysql     => $local_mysql,
    database_name   => $database_name,
    database_user   => $database_user,
    database_pass   => $database_pass,
    admin_username  => $admin_username,
    admin_pass      => $admin_pass,
    data_dir        => $data_dir,
    database_host   => $database_host,
    trusted_domains => [],
    install_method  => $install_method,
    create_data_dir => $create_data_dir,
  }->
  class { 'nextcloud::configure_ldap':
    ldap_password        => $ldap_password,
    ldap_base            => $ldap_base,
    ldap_dn              => $ldap_dn,
    ldap_group_filter    => $ldap_group_filter,
    ldap_host            => $ldap_host,
    ldap_login_filter    => $ldap_login_filter,
    ldap_userlist_filter => $ldap_userlist_filter,
    require              => Class['nextcloud'],
  }

  if ($proxy_trusted_proxies != undef) {
    class { 'nextcloud::configure_proxy':
      proxy_trusted_proxies   => $proxy_trusted_proxies,
      proxy_overwritehost     => $proxy_overwritehost,
      proxy_overwriteprotocol => $proxy_overwriteprotocol,
      require                 => Class['nextcloud'],
    }
  }
  class { 'nextcloud::configure_redis':
    redis_host => '/var/run/redis/redis.sock',
    redis_port => 0,
    require    => Class['nextcloud'],
  }

  if !defined(Class['firewall']) {
    class { 'firewall':
    }
  }
  firewall { '443-httpd':
    dport   => '443',
    action  => 'accept',
    require => Class['Firewall']
  }
  firewall { '80-httpd':
    dport   => '80',
    action  => 'accept',
    require => Class['Firewall']
  }
}
