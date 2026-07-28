<?php
header('Content-Type: text/event-stream');
echo "data: first\n\n";
flush();
usleep(2000000);
echo "data: second\n\n";
flush();
