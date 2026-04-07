---
title: BookStack
git_url: https://github.com/BookStackApp/BookStack.git
branch: development
---

PHP / Laravel wiki & documentation platform. Tests the setup agent against a Laravel + MySQL stack. Expects `composer install`, `npm install && npm run build`, MySQL configured via env, `php artisan migrate`, and `php artisan serve --host=0.0.0.0` returning HTTP 200 (or a redirect to /login).
