<?php

header('Content-Type: application/json');

echo json_encode([
    'extension' => extension_loaded('sodium'),
    'aead_key_bytes' => defined('SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES'),
]);
