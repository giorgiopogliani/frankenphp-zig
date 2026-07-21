<?php

declare(strict_types=1);

if (($_SERVER['FRANKENPHP_WORKER'] ?? null) !== '1' || !function_exists('frankenphp_handle_request')) {
    throw new RuntimeException('worker mode is unavailable');
}

$requestCount = 0;
$maxRequests = (int) ($_SERVER['MAX_REQUESTS'] ?? 1000);

while ($requestCount < $maxRequests && frankenphp_handle_request(static function () use (&$requestCount): void {
    if ($_SERVER['REQUEST_URI'] === '/exit') {
        exit(1);
    }
    $requestCount++;
    if ($_SERVER['REQUEST_URI'] === '/buffer') {
        ob_start();
        echo 'buffered:';
    }
    header('Content-Type: application/json');
    $response = [
        'count' => $requestCount,
        'uri' => $_SERVER['REQUEST_URI'],
    ];
    if (str_starts_with($_SERVER['REQUEST_URI'], '/inspect')) {
        $response += [
            'raw_body' => file_get_contents('php://input'),
            'get' => $_GET['q'] ?? null,
            'post' => $_POST['alpha'] ?? null,
            'cookie' => $_COOKIE['session'] ?? null,
            'files' => array_keys($_FILES),
            'output_level' => ob_get_level(),
            'session_available' => extension_loaded('session'),
        ];
    }
    if ($_SERVER['REQUEST_URI'] === '/session' && extension_loaded('session')) {
        session_id('worker-' . getmypid());
        session_start();
        $_SESSION['count'] = ($_SESSION['count'] ?? 0) + 1;
        $response['session_count'] = $_SESSION['count'];
        session_write_close();
    }
    echo json_encode($response, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
})) {
}
