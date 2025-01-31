#!/usr/bin/env bash

if [ $# -lt 3 ]; then
	echo "usage: $0 <db-name> <db-user> <db-pass> [db-host] [wp-version] [skip-database-creation]"
	exit 1
fi

sudo apt-get update && sudo apt-get install subversion
sudo -E docker-php-ext-install mysqli
sudo sh -c "printf '\ndeb http://ftp.us.debian.org/debian sid main\n' >> /etc/apt/sources.list"
sudo apt-get update && sudo apt-get install mysql-client-5.7

DB_NAME=$1
DB_USER=$2
DB_PASS=$3
DB_HOST=${4-localhost}
WP_VERSION=${5-latest}
SKIP_DB_CREATE=${6-false}

TMPDIR=${TMPDIR-/var/www/html}
TMPDIR=$(echo $TMPDIR | sed -e "s/\/$//")
WP_TESTS_DIR=${WP_TESTS_DIR-$TMPDIR/wordpress-tests-lib}
WP_CORE_DIR=${WP_CORE_DIR-$TMPDIR/wordpress/}

rm -rf $WP_TESTS_DIR $WP_CORE_DIR

download() {
	if [ `which curl` ]; then
		curl -s "$1" > "$2";
	elif [ `which wget` ]; then
		wget -nv -O "$2" "$1"
	fi
}

if [[ $WP_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
	WP_TESTS_TAG="branches/$WP_VERSION"
elif [[ $WP_VERSION =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
	if [[ $WP_VERSION =~ [0-9]+\.[0-9]+\.[0] ]]; then
		# version x.x.0 means the first release of the major version, so strip off the .0 and download version x.x
		WP_TESTS_TAG="tags/${WP_VERSION%??}"
	else
		WP_TESTS_TAG="tags/$WP_VERSION"
	fi
elif [[ $WP_VERSION == 'nightly' || $WP_VERSION == 'trunk' ]]; then
	WP_TESTS_TAG="trunk"
else
	# http serves a single offer, whereas https serves multiple. we only want one
	download http://api.wordpress.org/core/version-check/1.7/ /var/www/html/wp-latest.json
	grep '[0-9]+\.[0-9]+(\.[0-9]+)?' /var/www/html/wp-latest.json
	LATEST_VERSION=$(grep -o '"version":"[^"]*' /var/www/html/wp-latest.json | sed 's/"version":"//')
	if [[ -z "$LATEST_VERSION" ]]; then
		echo "Latest WordPress version could not be found"
		exit 1
	fi
	WP_TESTS_TAG="tags/$LATEST_VERSION"
fi

set -ex

install_wp() {

	if [ -d $WP_CORE_DIR ]; then
		return;
	fi

	mkdir -p $WP_CORE_DIR

	if [[ $WP_VERSION == 'nightly' || $WP_VERSION == 'trunk' ]]; then
		mkdir -p $TMPDIR/wordpress-nightly
		download https://wordpress.org/nightly-builds/wordpress-latest.zip  $TMPDIR/wordpress-nightly/wordpress-nightly.zip
		unzip -q $TMPDIR/wordpress-nightly/wordpress-nightly.zip -d $TMPDIR/wordpress-nightly/
		mv $TMPDIR/wordpress-nightly/wordpress/* $WP_CORE_DIR
	else
		if [ $WP_VERSION == 'latest' ]; then
			local ARCHIVE_NAME='latest'
		elif [[ $WP_VERSION =~ [0-9]+\.[0-9]+ ]]; then
			# https serves multiple offers, whereas http serves single.
			download https://api.wordpress.org/core/version-check/1.7/ $TMPDIR/wp-latest.json
			if [[ $WP_VERSION =~ [0-9]+\.[0-9]+\.[0] ]]; then
				# version x.x.0 means the first release of the major version, so strip off the .0 and download version x.x
				LATEST_VERSION=${WP_VERSION%??}
			else
				# otherwise, scan the releases and get the most up to date minor version of the major release
				local VERSION_ESCAPED=`echo $WP_VERSION | sed 's/\./\\\\./g'`
				LATEST_VERSION=$(grep -o '"version":"'$VERSION_ESCAPED'[^"]*' $TMPDIR/wp-latest.json | sed 's/"version":"//' | head -1)
			fi
			if [[ -z "$LATEST_VERSION" ]]; then
				local ARCHIVE_NAME="wordpress-$WP_VERSION"
			else
				local ARCHIVE_NAME="wordpress-$LATEST_VERSION"
			fi
		else
			local ARCHIVE_NAME="wordpress-$WP_VERSION"
		fi
		download https://wordpress.org/${ARCHIVE_NAME}.tar.gz  $TMPDIR/wordpress.tar.gz
		tar --strip-components=1 -zxmf $TMPDIR/wordpress.tar.gz -C $WP_CORE_DIR
	fi

	download https://raw.github.com/markoheijnen/wp-mysqli/master/db.php $WP_CORE_DIR/wp-content/db.php
}

setup_wp() {
	wp config create \
		--dbname=wordpress \
		--dbuser=$DB_USER \
		--dbpass=$DB_PASS \
		--dbhost=$DB_HOST \
		--skip-check \
		--path=$WP_CORE_DIR

	wp db create --path=$WP_CORE_DIR
	wp core install \
		--url=http://go.test \
		--title="WordPress Site" \
		--admin_user=admin \
		--admin_password=password \
		--admin_email=admin@go.test \
		--skip-email \
		--path=$WP_CORE_DIR

	wp option set permalink_structure "/%postname%/" --path=$WP_CORE_DIR
}

install_test_suite() {
	# portable in-place argument for both GNU sed and Mac OSX sed
	if [[ $(uname -s) == 'Darwin' ]]; then
		local ioption='-i.bak'
	else
		local ioption='-i'
	fi

	# set up testing suite if it doesn't yet exist
	if [ ! -d $WP_TESTS_DIR ]; then
		# set up testing suite
		mkdir -p $WP_TESTS_DIR
		svn co --ignore-externals --quiet https://develop.svn.wordpress.org/${WP_TESTS_TAG}/tests/phpunit/includes/ $WP_TESTS_DIR/includes
		svn co --ignore-externals --quiet https://develop.svn.wordpress.org/${WP_TESTS_TAG}/tests/phpunit/data/ $WP_TESTS_DIR/data
	fi

	if [ ! -f wp-tests-config.php ]; then
		download https://develop.svn.wordpress.org/${WP_TESTS_TAG}/wp-tests-config-sample.php "$WP_TESTS_DIR"/wp-tests-config.php
		# remove all forward slashes in the end
		WP_CORE_DIR=$(echo $WP_CORE_DIR | sed "s:/\+$::")
		sed $ioption "s:dirname( __FILE__ ) . '/src/':'$WP_CORE_DIR/':" "$WP_TESTS_DIR"/wp-tests-config.php
		sed $ioption "s/youremptytestdbnamehere/$DB_NAME/" "$WP_TESTS_DIR"/wp-tests-config.php
		sed $ioption "s/yourusernamehere/$DB_USER/" "$WP_TESTS_DIR"/wp-tests-config.php
		sed $ioption "s/yourpasswordhere/$DB_PASS/" "$WP_TESTS_DIR"/wp-tests-config.php
		sed $ioption "s|localhost|${DB_HOST}|" "$WP_TESTS_DIR"/wp-tests-config.php
	fi

}

install_db() {

	if [ ${SKIP_DB_CREATE} = "true" ]; then
		return 0
	fi

	# parse DB_HOST for port or socket references
	local PARTS=(${DB_HOST//\:/ })
	local DB_HOSTNAME=${PARTS[0]};
	local DB_SOCK_OR_PORT=${PARTS[1]};
	local EXTRA=""

	if ! [ -z $DB_HOSTNAME ] ; then
		if [ $(echo $DB_SOCK_OR_PORT | grep -e '^[0-9]\{1,\}$') ]; then
			EXTRA=" --host=$DB_HOSTNAME --port=$DB_SOCK_OR_PORT --protocol=tcp"
		elif ! [ -z $DB_SOCK_OR_PORT ] ; then
			EXTRA=" --socket=$DB_SOCK_OR_PORT"
		elif ! [ -z $DB_HOSTNAME ] ; then
			EXTRA=" --host=$DB_HOSTNAME --protocol=tcp"
		fi
	fi

	# create database
	mysqladmin create $DB_NAME --user="$DB_USER" --password="$DB_PASS"$EXTRA
}

install_rsync() {

	if [ ! -z $(which rsync) ]; then
		return 0
	fi

	sudo apt-get update --allow-releaseinfo-change
	sudo apt install rsync

}

install_wp
setup_wp
install_test_suite
install_db

if [ "$CIRCLE_JOB" == 'theme-check' ]; then
	php -d memory_limit=1024M "$(which wp)" package install anhskohbo/wp-cli-themecheck
	wp plugin install theme-check --activate --path=$WP_CORE_DIR
	cd ~/.wp-cli/packages/vendor/anhskohbo/wp-cli-themecheck && git pull
fi

if [[ "$CIRCLE_JOB" == 'a11y-tests' || "$CIRCLE_JOB" == 'visual-regression-chrome' || "$CIRCLE_JOB" == 'visual-regression-firefox' ]]; then
	sudo cp ~/project/.dev/tests/apache-ci.conf /etc/apache2/sites-available
	sudo a2ensite apache-ci.conf
	sudo a2enmod rewrite
	sudo service apache2 restart
fi

if [[ "$CIRCLE_JOB" == 'a11y-tests' ]]; then
	wp db reset --yes --path=$WP_CORE_DIR
	wp db import ~/project/.dev/tests/a11y-test-db.sql --path=$WP_CORE_DIR
	wp search-replace https://go.test http://go.test --path=$WP_CORE_DIR
fi

export INSTALL_PATH=$WP_CORE_DIR/wp-content/themes/go
mkdir -p $INSTALL_PATH

# If the ~/project/go directory exists, it persisted from the build job
if [ -d ~/project/go ]; then
	cp -r ~/project/go/* $INSTALL_PATH/
else
	install_rsync
	rsync -av --exclude-from ~/project/.distignore --delete ~/project/. $INSTALL_PATH/
fi

# PHPUnit requires the configuration file, the .dev/tests directory and
# the languages directory (which is not shipped in the build)
if [[ "$CIRCLE_JOB" == 'unit-tests' ]]; then
	cp -r ~/project/languages $INSTALL_PATH/
	cp ~/project/composer.json $INSTALL_PATH/
	cp ~/project/composer.lock $INSTALL_PATH/
	cp -r ~/project/.dev $INSTALL_PATH/
	cp ~/project/phpunit.xml $INSTALL_PATH/
fi

# Visual regression tests need the .dev and the languages directories
if [[ "$CIRCLE_JOB" == 'visual-regression-chrome' || "$CIRCLE_JOB" == 'visual-regression-firefox' ]]; then
	cp ~/project/composer.json $INSTALL_PATH/
	cp ~/project/composer.lock $INSTALL_PATH/
	cp -r ~/project/languages $INSTALL_PATH/
	cp -r ~/project/.dev $INSTALL_PATH/
	wp theme activate go --path=$WP_CORE_DIR
fi
