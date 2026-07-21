<?php

declare(strict_types=1);

// A valid worker must enter frankenphp_handle_request(). Returning from the
// bootstrap script is an initialization failure, not a reason to spin.
