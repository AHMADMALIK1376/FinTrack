<?php
/**
 * FinTrack entry point for PHP's built-in web server:
 *   php -S localhost:3000 -t ../frontend router.php      (or: npm start)
 * Requests to /api/... are answered by the API; everything else is a file
 * from ../frontend (the website), served by PHP directly.
 */
declare(strict_types=1);

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';

if (!str_starts_with($path, '/api/')) {
    if ($path === '/') {
        header('Location: /index.html');
        return true;
    }
    return false; // let the built-in server send the website file
}

require __DIR__ . '/src/app.php';
handle_request($_SERVER['REQUEST_METHOD'] ?? 'GET', $path);
