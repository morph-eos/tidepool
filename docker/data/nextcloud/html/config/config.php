<?php
$CONFIG = array (
  'htaccess.RewriteBase' => '/',
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'apps_paths' => 
  array (
    0 => 
    array (
      'path' => '/var/www/html/apps',
      'url' => '/apps',
      'writable' => false,
    ),
    1 => 
    array (
      'path' => '/var/www/html/custom_apps',
      'url' => '/custom_apps',
      'writable' => true,
    ),
  ),
  'memcache.distributed' => '\\OC\\Memcache\\Redis',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' => 
  array (
    'host' => 'nextcloud-redis',
    'password' => '',
    'port' => 6379,
  ),
  'overwriteprotocol' => 'https',
  'overwrite.cli.url' => 'https://cloud.REDACTED_DOMAIN',
  'upgrade.disable-web' => true,
  'passwordsalt' => 'REDACTED_NEXTCLOUD_CONFIG',
  'secret' => 'REDACTED_NEXTCLOUD_CONFIG',
  'trusted_domains' => 
  array (
    0 => 'localhost',
    1 => 'cloud.REDACTED_DOMAIN',
    2 => 'cloud.REDACTED_HOSTNAME.REDACTED_DDNS',
  ),
  'datadirectory' => '/var/www/html/data',
  'dbtype' => 'mysql',
  'version' => '33.0.2.2',
  'dbname' => 'nextcloud',
  'dbhost' => 'nextcloud-db',
  'dbport' => '',
  'dbtableprefix' => 'oc_',
  'mysql.utf8mb4' => true,
  'dbuser' => 'nextcloud',
  'dbpassword' => 'REDACTED_NEXTCLOUD_CONFIG',
  'installed' => true,
  'instanceid' => 'REDACTED_NC_INSTANCEID',
  'maintenance' => false,
  'loglevel' => 0,
  'mail_smtpmode' => 'smtp',
  'mail_smtphost' => 'smtp-relay.REDACTED_SMTP_PROVIDER.com',
  'mail_smtpport' => '587',
  'mail_smtpsecure' => 'tls',
  'mail_smtpauth' => '1',
  'mail_smtpauthtype' => 'LOGIN',
  'mail_smtpname' => 'REDACTED_SMTP_ACCOUNT',
  'mail_smtppassword' => 'REDACTED_BITWARDEN_SMTP_PASSWORD',
  'mail_from_address' => 'noreply',
  'mail_domain' => 'REDACTED_DOMAIN',
  'trusted_proxies' => 
  array (
    0 => '172.18.0.0/16',
  ),
  'forwarded_for_headers' => 
  array (
    0 => 'HTTP_X_FORWARDED_FOR',
  ),
);
