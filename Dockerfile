FROM debian:8.8
MAINTAINER David Ramsington <grokbot.dwr@gmail.com>

# Set some Environment variables + Build Arguments
ENV DEBIAN_FRONTEND noninteractive
ENV APP_HOST blackmail.local
ENV DB_PASS secret
ARG DB_ROOT_PASS
ENV DB_ROOT_PASS secret

# Upgrade the container
RUN apt-get update && \
    apt-get upgrade -y

# Install basic tools
RUN apt-get install -y --no-install-recommends \
    curl \
    unzip \
    lsof \
    procps \
    wget \
    bzip2

# Get dependencies from external sources
# Reference: https://www.howtoforge.com/tutorial/how-to-install-php-7-on-debian/
# Mirror: http://de1.php.net/get/php-7.1.2.tar.bz2/from/this/mirror
# Memcached Repo: https://github.com/php-memcached-dev/php-memcached/archive/php7.zip
COPY /pkg/php-7.1.2.tar.bz2 /opt/php-7.1/build/php-7.1.2.tar.bz2
COPY /pkg/php-memcached-php7.zip /opt/php-7.1/build/php-memcached/php-memcached-php7.zip
WORKDIR /opt/php-7.1/build/
RUN tar jxf php-7.1.2.tar.bz2
WORKDIR /opt/php-7.1/build/php-memcached
RUN unzip php-memcached-php7.zip

# Install libraries needed for building + linking c lib to actual location
RUN apt-get install -y --no-install-recommends build-essential nano autoconf libfcgi-dev libfcgi0ldbl \
	libjpeg62-turbo-dbg libmcrypt-dev libssl-dev libc-client2007e libc-client2007e-dev \
	libxml2-dev libbz2-dev libcurl4-openssl-dev libjpeg-dev libpng12-dev libfreetype6-dev \
	libkrb5-dev libpq-dev libxml2-dev libxslt1-dev libmemcached-dev pkg-config software-properties-common && \
	ln -s /usr/lib/libc-client.a /usr/lib/x86_64-linux-gnu/libc-client.a

WORKDIR /opt/php-7.1/build/php-7.1.2

# FULL LIST: ./configure --help
RUN ./configure --prefix=/opt/php-7.1 --with-pdo-pgsql --with-zlib-dir --with-freetype-dir --enable-mbstring --with-libxml-dir=/usr --with-curl --with-mcrypt --with-zlib \
	--with-gd --with-pgsql --disable-rpath --enable-inline-optimization --with-bz2 --with-zlib --enable-sockets --enable-sysvsem --enable-sysvshm --enable-pcntl \
	--enable-mbregex --enable-exif --enable-bcmath --with-mhash --enable-zip --with-pcre-regex --with-pdo-mysql --with-mysqli --enable-soap \
	--with-mysql-sock=/var/run/mysqld/mysqld.sock --with-jpeg-dir=/usr --with-png-dir=/usr --enable-gd-native-ttf --with-openssl --with-fpm-user=www-data \
	--with-fpm-group=www-data --with-libdir=/lib/x86_64-linux-gnu --enable-ftp --with-imap --with-imap-ssl --with-kerberos --with-gettext --with-xmlrpc --with-xsl \
	--enable-opcache --enable-fpm && \
	make && make install

# Install memcached
WORKDIR /opt/php-7.1/build/php-memcached/php-memcached-php7/
RUN ln -s /opt/php-7.1/bin/php /usr/bin/php && \
	ln -s /opt/php-7.1/bin/pear /usr/bin/pear && \
	ln -s /opt/php-7.1/bin/pecl /usr/bin/pecl && \
	ln -s /opt/php-7.1/bin/phpize /usr/bin/phpize && \
	phpize && ./configure --with-php-config=/opt/php-7.1/bin/php-config && \
	make && make install

# Install xdebug
RUN pecl -C /opt/php-7.1/etc/pear.conf update-channels && \
	pecl -C /opt/php-7.1/etc/pear.conf install xdebug

# Copy PHP Configuration
COPY ./conf/php-fpm.conf /opt/php-7.1/etc/php-fpm.conf
COPY ./conf/php.ini /opt/php-7.1/lib/php.ini
COPY ./conf/www.conf /opt/php-7.1/etc/php-fpm.d/www.conf

# Add Repos, GPG keys and Install NGINX + Node/NPM + MySQL + Redis
WORKDIR /tmp
COPY ./repo/* /etc/apt/sources.list.d/
RUN curl http://nginx.org/keys/nginx_signing.key | apt-key add - && \
    curl --silent https://packagecloud.io/gpg.key | apt-key add - && \
    apt-key adv --keyserver ha.pool.sks-keyservers.net --recv-keys 5072E1F5 && \
    wget https://www.dotdeb.org/dotdeb.gpg && \
    apt-key add dotdeb.gpg && \
    curl --silent https://deb.nodesource.com/setup_7.x | bash - && \
    echo mysql-server mysql-server/root_password password $DB_ROOT_PASS | debconf-set-selections;\
    echo mysql-server mysql-server/root_password_again password $DB_ROOT_PASS | debconf-set-selections;\
    apt-get update && apt-get install --no-install-recommends -y nginx redis-server mysql-server mysql-client gettext && \
    echo "default_password_lifetime = 0" >> /etc/mysql/mysql.conf.d/mysqld.cnf

# Setup NGINX
COPY ./conf/nginx.conf /etc/nginx/nginx.conf
COPY ./conf/vhost.conf /tmp/nginx/vhost.conf
COPY ./conf/fastcgi_params /etc/nginx/fastcgi_params
RUN envsubst \$APP_HOST < /tmp/nginx/vhost.conf > /etc/nginx/conf.d/vhost.conf

# Create DB + User
RUN /usr/sbin/mysqld --user mysql & \
    sleep 10s && \
    echo "GRANT ALL ON *.* TO root@'0.0.0.0' IDENTIFIED BY '${DB_ROOT_PASS}' WITH GRANT OPTION; CREATE USER 'spark'@'0.0.0.0' IDENTIFIED BY '${DB_PASS}'; GRANT ALL ON *.* TO 'spark'@'0.0.0.0' IDENTIFIED BY '${DB_PASS}' WITH GRANT OPTION; GRANT ALL ON *.* TO 'spark'@'%' IDENTIFIED BY '${DB_PASS}' WITH GRANT OPTION; FLUSH PRIVILEGES; CREATE DATABASE spark;" | mysql

# Install utility aliases
COPY ./utils/.bash_aliases /root/.bash_aliases

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer && \
    printf "\nPATH=\"~/.composer/vendor/bin:\$PATH\"\n" | tee -a ~/.bashrc

# Install Laravel Envoy
RUN composer global require "laravel/envoy"

# Install Laravel installer
RUN composer global require "laravel/installer" && \
    ln -s /root/.composer/vendor/bin/laravel /usr/bin/laravel

# Install Spark installer
RUN composer global require "laravel/spark-installer"

# install nodejs
RUN apt-get install -y nodejs

# Install gulp + bower
RUN /usr/bin/npm install -g gulp && \
	/usr/bin/npm install -g bower

# Install Supervisor
RUN apt-get install -y supervisor git-core && \
    mkdir -p /var/log/supervisor
COPY ./conf/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# clean up our mess
RUN apt-get remove --purge -y software-properties-common && \
    apt-get autoremove -y && \
    apt-get clean && \
    apt-get autoclean && \
    echo -n > /var/lib/apt/extended_states && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /usr/share/man/?? && \
    rm -rf /usr/share/man/??_*

# Expose Ports
EXPOSE 80 443 3306 6379

# Create Virtual Host Directory
WORKDIR /var/www/html/
RUN mkdir app && chown -R www-data:www-data ./app/

# Set Container Entrypoint + Command
COPY ./scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
CMD ["start"]