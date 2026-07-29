<?php

if ($_SERVER['PATH_INFO'] === '/slow') {
    sleep(10);
}
if ($_SERVER['PATH_INFO'] === '/loop') {
    while (true) {
    }
}
if ($_SERVER['PATH_INFO'] === '/not-found') {
    http_response_code(404);
}

header('Content-Type: application/json');
header('X-FrankenPHP-Engine: zig');

echo json_encode([
    'pid' => getmypid(),
    'method' => $_SERVER['REQUEST_METHOD'],
    'path' => $_SERVER['PATH_INFO'],
    'query' => $_GET,
    'body' => file_get_contents('php://input'),
    'remote_addr' => $_SERVER['REMOTE_ADDR'],
    'remote_port' => $_SERVER['REMOTE_PORT'],
    'server_name' => $_SERVER['SERVER_NAME'],
    'server_port' => $_SERVER['SERVER_PORT'],
    'cookies' => $_COOKIE,
]);
