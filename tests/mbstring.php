<?php

header('Content-Type: application/json');

echo json_encode([
    'extension' => extension_loaded('mbstring'),
    'function' => function_exists('mb_convert_encoding'),
]);
