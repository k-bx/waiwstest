document.addEventListener('DOMContentLoaded', function(){

    function createWebSocket(path) {
        var host = window.location.hostname;
        if(host == '') host = 'localhost';
        var uri = 'ws://' + host
                + (window.location.port ? ':' + window.location.port : '')
                + path;

        return new WebSocket(uri);
    }

    var _pingSenderLastPong = new Date();
    var _pingSenderThread = null;
    function setupPingSender() {
        console.log("Setup of ping sender");
        if (_pingSenderThread) {
            console.log("Cleared old ping sender thread");
            clearInterval(_pingSenderThread);
        }
        sendPing();
        _pingSenderThread = setInterval(sendPing, 5000);
    }
    function sendPing() {
        console.log("Seconds since last pong: ", (new Date() - _pingSenderLastPong) / 1000);
        console.log("Sending ping");
        ws.send("ping");
    }

    // app starts here

    console.log("Starting up");
    var wsOnOpen = function() {
        console.log("wsOnOpen. Will start pinging.");
        setupPingSender(ws);
    }
    var wsOnMessage = function(ev) {
        console.log("Got data from server: ", ev.data);
        if (ev.data == "pong") {
            _pingSenderLastPong = new Date();
        }
    }
    var wsOnError = function(e) {
        console.log("Error happened: ", e);
    }
    var wsOnClose = function(e) {
        console.log("Onclose event: ", e);
        console.log("Creating new ws");
        ws = createWs(ws);
    }
    var createWs = function() {
        ws = createWebSocket('/');
        ws.onopen = wsOnOpen;
        ws.onmessage = wsOnMessage;
        ws.onerror = wsOnError;
        ws.onclose = wsOnClose;
        return ws;
    }

    var ws = createWs();

    window.addEventListener('beforeunload', function() {
        console.log("Beforeunload. Closing socket.");
        ws.close();
    });
});
