<?php

declare(strict_types=1);

$handler = static function (): void {
    require __DIR__ . '/index.php';
};

$maxRequests = (int) ($_SERVER['MAX_REQUESTS'] ?? 0);

for ($requestCount = 0; !$maxRequests || $requestCount < $maxRequests; ++$requestCount) {
    $keepRunning = frankenphp_handle_request($handler);
    gc_collect_cycles();

    if (!$keepRunning) {
        break;
    }
}