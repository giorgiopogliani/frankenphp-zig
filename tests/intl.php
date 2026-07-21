<?php

header('Content-Type: application/json');

$formatter = new NumberFormatter('en_US', NumberFormatter::DECIMAL);

echo json_encode([
    'extension' => extension_loaded('intl'),
    'formatter' => $formatter->format(1234.5) !== false,
]);
