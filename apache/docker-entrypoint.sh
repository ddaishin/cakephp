#!/bin/bash
set -e

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	if [ -n "$MYSQL_PORT_3306_TCP" ]; then
		if [ -z "$CAKEPHP_DB_HOST" ]; then
			CAKEPHP_DB_HOST='mysql'
		else
			echo >&2 'warning: both CAKEPHP_DB_HOST and MYSQL_PORT_3306_TCP found'
			echo >&2 "  Connecting to CAKEPHP_DB_HOST ($CAKEPHP_DB_HOST)"
			echo >&2 '  instead of the linked mysql container'
		fi
	fi

	if [ -z "$CAKEPHP_DB_HOST" ]; then
		echo >&2 'error: missing CAKEPHP_DB_HOST and MYSQL_PORT_3306_TCP environment variables'
		echo >&2 '  Did you forget to --link some_mysql_container:mysql or set an external db'
		echo >&2 '  with -e CAKEPHP_DB_HOST=hostname:port?'
		exit 1
	fi

	# if we're linked to MySQL and thus have credentials already, let's use them
	: ${CAKEPHP_DB_USER:=${MYSQL_ENV_MYSQL_USER:-root}}
	if [ "$CAKEPHP_DB_USER" = 'root' ]; then
		: ${CAKEPHP_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}
	fi
	: ${CAKEPHP_DB_PASSWORD:=$MYSQL_ENV_MYSQL_PASSWORD}
	: ${CAKEPHP_DB_NAME:=${MYSQL_ENV_MYSQL_DATABASE:-cakephp}}

	if [ -z "$CAKEPHP_DB_PASSWORD" ]; then
		echo >&2 'error: missing required CAKEPHP_DB_PASSWORD environment variable'
		echo >&2 '  Did you forget to -e CAKEPHP_DB_PASSWORD=... ?'
		echo >&2
		echo >&2 '  (Also of interest might be CAKEPHP_DB_USER and CAKEPHP_DB_NAME.)'
		exit 1
	fi

	if ! [ -e index.php -a ]; then
		echo >&2 " not found in $(pwd) - copying now..."
		if [ "$(ls -A)" ]; then
			echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
			( set -x; ls -A; sleep 10 )
		fi

		if [ ! -d /usr/src/cakephp ]; then
			curl -SL https://github.com/cakephp/cakephp/archive/${CAKEPHP_VERSION:=master}.tar.gz | tar -xz -C /usr/src/cakephp --strip-components 1 \
			&& chown -R www-data:www-data /usr/src/cakephp
		fi

		tar cf - --one-file-system -C /usr/src/cakephp . | tar xf -
		echo >&2 "Complete! CakePHP has been successfully copied to $(pwd)"

	fi

	TERM=dumb php -- "$CAKEPHP_DB_HOST" "$CAKEPHP_DB_USER" "$CAKEPHP_DB_PASSWORD" "$CAKEPHP_DB_NAME" <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

$stderr = fopen('php://stderr', 'w');

list($host, $port) = explode(':', $argv[1], 2);

$maxTries = 10;
do {
	$mysql = new mysqli($host, $argv[2], $argv[3], '', (int)$port);
	if ($mysql->connect_error) {
		fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ($mysql->connect_error);

if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($argv[4]) . '`')) {
	fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}

$mysql->close();
EOPHP
fi

exec "$@"
