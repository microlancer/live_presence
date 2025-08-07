<?php
use Ratchet\MessageComponentInterface;
use Ratchet\ConnectionInterface;

require __DIR__ . '/vendor/autoload.php';

class MyWebSocketServer implements MessageComponentInterface {
    protected $clients;
    protected $latestMessages; // Store latest messages from each client

    public function __construct() {
        $this->clients = new SplObjectStorage;
        $this->latestMessages = new SplObjectStorage;
    }

    public function onOpen(ConnectionInterface $conn) {
        echo "New connection! (#{$conn->resourceId})\n";
        $this->clients->attach($conn);

        // Send the latest messages to the newly connected client
        foreach ($this->latestMessages as $client) {
            $message = $this->latestMessages[$client];
            $conn->send($message);
        }
    }

    public function onMessage(ConnectionInterface $from, $msg) {
        echo "Received message from #{$from->resourceId}: $msg\n";

        // Save the most recent message from this client
        $this->latestMessages[$from] = $msg;

        // Broadcast the message to all other clients
        foreach ($this->clients as $client) {
            if ($from !== $client) {
                $client->send($msg);
            }
        }
    }

    public function onClose(ConnectionInterface $conn) {
        echo "Connection #{$conn->resourceId} has disconnected\n";

        // Remove from both collections
        $this->clients->detach($conn);

        // Whether you want to clear the messages of disconnected clients is up to you
        if (false) {
            $this->latestMessages->detach($conn);
    
        }
    }

    public function onError(ConnectionInterface $conn, \Exception $e) {
        echo "Error on connection #{$conn->resourceId}: {$e->getMessage()}\n";
        $conn->close();
    }
}


use Ratchet\Server\IoServer;
use Ratchet\Http\HttpServer;
use Ratchet\WebSocket\WsServer;

$server = IoServer::factory(
    new HttpServer(
        new WsServer(
            new MyWebSocketServer()
        )
    ),
    1337
);

echo "WebSocket server started on port 1337\n";
$server->run();

