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
    // a page that doesn't exist gets FinTrack's friendly 404 page, not the server's plain one
    $file = realpath(__DIR__ . '/../frontend' . $path);
    $root = realpath(__DIR__ . '/../frontend');
    if ($file === false || !str_starts_with($file, $root . DIRECTORY_SEPARATOR) || !is_file($file)) {
        http_response_code(404);
        header('Content-Type: text/html; charset=utf-8');
        readfile($root . '/404.html');
        return true;
    }
    return false; // let the built-in server send the website file
}

require __DIR__ . '/src/app.php';

// The Android app (Capacitor) loads the pages from inside the app, at https://localhost, and calls
// this API from there. Browsers and app web views only allow that when the API says so (CORS).
// Only the app's own addresses are allowed; any other site gets no permission.
$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
$allowed = array_filter(array_map('trim', explode(',', env('CORS_ORIGINS', 'https://localhost,capacitor://localhost,http://localhost'))));
if ($origin !== '' && in_array($origin, $allowed, true)) {
    header('Access-Control-Allow-Origin: ' . $origin);
    header('Vary: Origin');
    header('Access-Control-Allow-Headers: Authorization, Content-Type');
    header('Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS');
    header('Access-Control-Max-Age: 600');
}
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') {
    http_response_code(204);
    return true;
}
handle_request($_SERVER['REQUEST_METHOD'] ?? 'GET', $path);
