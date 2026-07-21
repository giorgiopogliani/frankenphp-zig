<?php

header('Content-Type: application/json');

echo json_encode(PDO::getAvailableDrivers());
