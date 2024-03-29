#!/bin/bash
set -e

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

case "$1" in
	rails|rake|passenger)
		if [ ! -f './config/database.yml' ]; then
			file_env 'REDMINE_DB_MYSQL'
			file_env 'REDMINE_DB_POSTGRES'
			
			if [ "$MYSQL_PORT_3306_TCP" ] && [ -z "$REDMINE_DB_MYSQL" ]; then
				export REDMINE_DB_MYSQL='mysql'
			elif [ "$POSTGRES_PORT_5432_TCP" ] && [ -z "$REDMINE_DB_POSTGRES" ]; then
				export REDMINE_DB_POSTGRES='postgres'
			fi
			
			if [ "$REDMINE_DB_MYSQL" ]; then
				adapter='mysql2'
				host="$REDMINE_DB_MYSQL"
				file_env 'REDMINE_DB_PORT' '3306'
				file_env 'REDMINE_DB_USERNAME' "${MYSQL_ENV_MYSQL_USER:-root}"
				file_env 'REDMINE_DB_PASSWORD' "${MYSQL_ENV_MYSQL_PASSWORD:-${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
				file_env 'REDMINE_DB_DATABASE' "${MYSQL_ENV_MYSQL_DATABASE:-${MYSQL_ENV_MYSQL_USER:-redmine}}"
				file_env 'REDMINE_DB_ENCODING' ''
			elif [ "$REDMINE_DB_POSTGRES" ]; then
				adapter='postgresql'
				host="$REDMINE_DB_POSTGRES"
				file_env 'REDMINE_DB_PORT' '5432'
				file_env 'REDMINE_DB_USERNAME' "${POSTGRES_ENV_POSTGRES_USER:-postgres}"
				file_env 'REDMINE_DB_PASSWORD' "${POSTGRES_ENV_POSTGRES_PASSWORD}"
				file_env 'REDMINE_DB_DATABASE' "${POSTGRES_ENV_POSTGRES_DB:-${REDMINE_DB_USERNAME:-}}"
				file_env 'REDMINE_DB_ENCODING' 'utf8'
			else
				echo >&2
				echo >&2 'warning: missing REDMINE_DB_MYSQL or REDMINE_DB_POSTGRES environment variables'
				echo >&2
				echo >&2 '*** Using sqlite3 as fallback. ***'
				echo >&2
				
				adapter='sqlite3'
				host='localhost'
				file_env 'REDMINE_DB_PORT' ''
				file_env 'REDMINE_DB_USERNAME' 'redmine'
				file_env 'REDMINE_DB_PASSWORD' ''
				file_env 'REDMINE_DB_DATABASE' 'sqlite/redmine.db'
				file_env 'REDMINE_DB_ENCODING' 'utf8'
				
				mkdir -p "$(dirname "$REDMINE_DB_DATABASE")"
				chown -R root:root "$(dirname "$REDMINE_DB_DATABASE")"
			fi
			
			REDMINE_DB_ADAPTER="$adapter"
			REDMINE_DB_HOST="$host"
			echo "$RAILS_ENV:" > config/database.yml
			for var in \
				adapter \
				host \
				port \
				username \
				password \
				database \
				encoding \
			; do
				env="REDMINE_DB_${var^^}"
				val="${!env}"
				[ -n "$val" ] || continue
				echo "  $var: \"$val\"" >> config/database.yml
			done
		fi
		
		# ensure the right database adapter is active in the Gemfile.lock
		bundle install --without development test
		
		if [ ! -s config/secrets.yml ]; then
			file_env 'REDMINE_SECRET_KEY_BASE'
			if [ "$REDMINE_SECRET_KEY_BASE" ]; then
				cat > 'config/secrets.yml' <<-YML
					$RAILS_ENV:
					  secret_key_base: "$REDMINE_SECRET_KEY_BASE"
				YML
			elif [ ! -f /usr/src/redmine/config/initializers/secret_token.rb ]; then
				rake generate_secret_token
			fi
		fi
		if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
			gosu redmine rake db:migrate
		fi
		
		# https://www.redmine.org/projects/redmine/wiki/RedmineInstall#Step-8-File-system-permissions
		chown -R root:root files log public/plugin_assets
		chmod -R 755 files log tmp public/plugin_assets
		
		# remove PID file to enable restarting the container
		rm -f /usr/src/redmine/tmp/pids/server.pid
		
		if [ "$1" = 'passenger' ]; then
			# Don't fear the reaper.
			set -- tini -- "$@"
		fi
		
		set -- gosu redmine "$@"
		;;
esac

exec "$@"
