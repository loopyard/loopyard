FROM php:8.3-cli

RUN apt-get update && apt-get install -y \
    git curl unzip ca-certificates \
    libzip-dev libpng-dev libonig-dev libxml2-dev libsqlite3-dev \
    libpq-dev libicu-dev libjpeg-dev libfreetype6-dev \
    libldap2-dev libtidy-dev \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
       pdo_mysql pdo_pgsql pdo_sqlite mbstring exif pcntl bcmath gd zip intl ldap tidy

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
